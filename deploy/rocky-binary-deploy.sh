#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_DIR="/opt/sub2api"
CONFIG_DIR="/etc/sub2api"
SERVICE_NAME="sub2api"
SERVICE_USER="sub2api"
ARTIFACT_PATH=""
ADMIN_EMAIL="admin@sub2api.local"
ADMIN_PASSWORD=""
SERVER_PORT="8080"
TZ_VALUE="Asia/Shanghai"
DB_NAME="sub2api"
DB_USER="sub2api"
DB_PASSWORD=""
SKIP_FIREWALL="0"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash deploy/rocky-binary-deploy.sh --artifact /tmp/sub2api-binary.tar.gz [options]

Options:
  --artifact <path>           Uploaded artifact tar.gz path
  --admin-email <email>       Admin email. Default: admin@sub2api.local
  --admin-password <pwd>      Admin password. Default: auto-generated
  --port <port>               Service port. Default: 8080
  --tz <timezone>             Timezone. Default: Asia/Shanghai
  --db-name <name>            PostgreSQL database name. Default: sub2api
  --db-user <user>            PostgreSQL user. Default: sub2api
  --db-password <pwd>         PostgreSQL password. Default: auto-generated
  --skip-firewall             Do not modify firewalld
  --help                      Show this message
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

escape_sql_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

escape_systemd_env() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

read_env_value() {
  local file="$1"
  local key="$2"
  local raw

  [[ -f "${file}" ]] || return 0
  raw="$(grep -E "^${key}=" "${file}" | tail -n 1 || true)"
  [[ -n "${raw}" ]] || return 0
  raw="${raw#*=}"
  raw="${raw%$'\r'}"
  if [[ "${raw}" == \"*\" && "${raw}" == *\" ]]; then
    raw="${raw:1:${#raw}-2}"
    raw="${raw//\\\"/\"}"
    raw="${raw//\\\\/\\}"
  fi
  printf '%s' "${raw}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --artifact)
        ARTIFACT_PATH="$2"
        shift 2
        ;;
      --admin-email)
        ADMIN_EMAIL="$2"
        shift 2
        ;;
      --admin-password)
        ADMIN_PASSWORD="$2"
        shift 2
        ;;
      --port)
        SERVER_PORT="$2"
        shift 2
        ;;
      --tz)
        TZ_VALUE="$2"
        shift 2
        ;;
      --db-name)
        DB_NAME="$2"
        shift 2
        ;;
      --db-user)
        DB_USER="$2"
        shift 2
        ;;
      --db-password)
        DB_PASSWORD="$2"
        shift 2
        ;;
      --skip-firewall)
        SKIP_FIREWALL="1"
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

install_packages() {
  log "Installing system packages..."
  dnf -y install postgresql-server postgresql valkey openssl tar >/dev/null
}

init_postgres() {
  if [[ -f /var/lib/pgsql/data/PG_VERSION ]]; then
    log "PostgreSQL data directory already initialized."
  else
    log "Initializing PostgreSQL..."
    if command_exists postgresql-setup; then
      postgresql-setup --initdb >/dev/null
    elif [[ -x /usr/bin/postgresql-setup ]]; then
      /usr/bin/postgresql-setup --initdb >/dev/null
    else
      die "postgresql-setup not found after package installation."
    fi
  fi

  log "Configuring PostgreSQL local authentication..."
  sed -i \
    -e 's/^local\s\+all\s\+all\s\+peer$/local   all             all                                     scram-sha-256/' \
    -e 's/^host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+ident$/host    all             all             127.0.0.1\/32            scram-sha-256/' \
    -e 's/^host\s\+all\s\+all\s\+::1\/128\s\+ident$/host    all             all             ::1\/128                 scram-sha-256/' \
    /var/lib/pgsql/data/pg_hba.conf
}

start_data_services() {
  log "Starting PostgreSQL and Valkey..."
  systemctl enable --now postgresql
  systemctl enable --now valkey
}

ensure_firewall() {
  if [[ "${SKIP_FIREWALL}" == "1" ]]; then
    return
  fi

  if systemctl is-active firewalld >/dev/null 2>&1; then
    log "Opening firewall port ${SERVER_PORT}/tcp..."
    firewall-cmd --permanent --add-port="${SERVER_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  else
    warn "firewalld is not active, skipping firewall changes."
  fi
}

wait_for_postgres() {
  log "Waiting for PostgreSQL..."
  for _ in $(seq 1 30); do
    if runuser -u postgres -- psql -d postgres -Atqc "SELECT 1" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  die "PostgreSQL did not become ready."
}

ensure_database() {
  local role_exists db_exists sql_password existing_env existing_db_password

  existing_env="${CONFIG_DIR}/sub2api.env"
  if [[ -z "${DB_PASSWORD}" && -f "${existing_env}" ]]; then
    existing_db_password="$(read_env_value "${existing_env}" "DATABASE_PASSWORD")"
    if [[ -n "${existing_db_password}" ]]; then
      DB_PASSWORD="${existing_db_password}"
    fi
  fi
  [[ -n "${DB_PASSWORD}" ]] || DB_PASSWORD="$(openssl rand -hex 24)"
  sql_password="$(escape_sql_literal "${DB_PASSWORD}")"

  role_exists="$(runuser -u postgres -- psql -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" || true)"
  if [[ "${role_exists}" != "1" ]]; then
    log "Creating PostgreSQL role ${DB_USER}..."
    runuser -u postgres -- psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${sql_password}';" >/dev/null
  fi

  db_exists="$(runuser -u postgres -- psql -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" || true)"
  if [[ "${db_exists}" != "1" ]]; then
    log "Creating PostgreSQL database ${DB_NAME}..."
    runuser -u postgres -- psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};" >/dev/null
  fi
}

ensure_service_user() {
  if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    return
  fi

  log "Creating service user ${SERVICE_USER}..."
  useradd -r -s /sbin/nologin -d "${INSTALL_DIR}" "${SERVICE_USER}"
}

install_artifact() {
  [[ -f "${ARTIFACT_PATH}" ]] || die "Artifact not found: ${ARTIFACT_PATH}"

  log "Installing artifact into ${INSTALL_DIR}..."
  mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
  rm -rf "${INSTALL_DIR}/bin" "${INSTALL_DIR}/resources"
  mkdir -p "${INSTALL_DIR}/bin"
  tar xzf "${ARTIFACT_PATH}" -C "${INSTALL_DIR}"
  chmod +x "${INSTALL_DIR}/sub2api"
  mkdir -p "${INSTALL_DIR}/data"
  chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}" "${INSTALL_DIR}/sub2api" "${INSTALL_DIR}/data"
  if [[ -d "${INSTALL_DIR}/resources" ]]; then
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/resources"
  fi
}

write_env_file() {
  local env_file jwt_secret totp_key existing_admin_password

  env_file="${CONFIG_DIR}/sub2api.env"
  jwt_secret="$(read_env_value "${env_file}" "JWT_SECRET")"
  totp_key="$(read_env_value "${env_file}" "TOTP_ENCRYPTION_KEY")"
  existing_admin_password="$(read_env_value "${env_file}" "ADMIN_PASSWORD")"

  [[ -n "${jwt_secret}" ]] || jwt_secret="$(openssl rand -hex 32)"
  [[ -n "${totp_key}" ]] || totp_key="$(openssl rand -hex 32)"
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    if [[ -n "${existing_admin_password}" ]]; then
      ADMIN_PASSWORD="${existing_admin_password}"
    else
      ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '\n')"
    fi
  fi

  umask 077
  cat >"${env_file}" <<EOF
AUTO_SETUP=true
DATA_DIR=${INSTALL_DIR}/data
SERVER_HOST=0.0.0.0
SERVER_PORT=${SERVER_PORT}
SERVER_MODE=release
RUN_MODE=standard
TZ=$(escape_systemd_env "${TZ_VALUE}")
DATABASE_HOST=127.0.0.1
DATABASE_PORT=5432
DATABASE_USER=${DB_USER}
DATABASE_PASSWORD=$(escape_systemd_env "${DB_PASSWORD}")
DATABASE_DBNAME=${DB_NAME}
DATABASE_SSLMODE=disable
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=
REDIS_DB=0
REDIS_ENABLE_TLS=false
ADMIN_EMAIL=$(escape_systemd_env "${ADMIN_EMAIL}")
ADMIN_PASSWORD=$(escape_systemd_env "${ADMIN_PASSWORD}")
JWT_SECRET=${jwt_secret}
JWT_EXPIRE_HOUR=24
TOTP_ENCRYPTION_KEY=${totp_key}
EOF
  chmod 600 "${env_file}"
}

write_service() {
  log "Writing systemd service..."
  cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Sub2API - AI API Gateway Platform
After=network.target postgresql.service valkey.service
Wants=postgresql.service valkey.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONFIG_DIR}/sub2api.env
ExecStart=${INSTALL_DIR}/sub2api
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sub2api
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR} ${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
}

print_summary() {
  local host_ip

  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "${host_ip}" ]] || host_ip="SERVER_IP"

  printf 'URL: http://%s:%s\n' "${host_ip}" "${SERVER_PORT}"
  printf 'Admin: %s / %s\n' "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}"
  printf 'DB: %s / %s / %s\n' "${DB_NAME}" "${DB_USER}" "${DB_PASSWORD}"
  printf 'Logs: journalctl -u %s -f\n' "${SERVICE_NAME}"
}

main() {
  parse_args "$@"
  require_root
  [[ -n "${ARTIFACT_PATH}" ]] || die "--artifact is required."
  install_packages
  init_postgres
  start_data_services
  ensure_firewall
  wait_for_postgres
  ensure_database
  ensure_service_user
  install_artifact
  write_env_file
  write_service
  print_summary
}

main "$@"
