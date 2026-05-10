#!/usr/bin/env bash

set -Eeuo pipefail

SERVER_NAME=""
UPSTREAM_HOST="127.0.0.1"
UPSTREAM_PORT="8080"
CERT_MODE="self-signed"
LETSENCRYPT_EMAIL=""
NGINX_CONF_PATH="/etc/nginx/conf.d/sub2api.conf"
UNDERSCORE_CONF_PATH="/etc/nginx/conf.d/00-sub2api-http.conf"
CERT_DIR="/etc/nginx/certs"
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
  bash deploy/rocky-nginx-https.sh [options]

Options:
  --server-name <name>       Domain or IP to serve. Default: first host IP
  --upstream-host <host>     Upstream host. Default: 127.0.0.1
  --upstream-port <port>     Upstream port. Default: 8080
  --cert-mode <mode>         self-signed or letsencrypt. Default: self-signed
  --email <email>            Email for Let's Encrypt
  --skip-firewall            Do not modify firewalld
  --help                     Show this message
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-name)
        SERVER_NAME="$2"
        shift 2
        ;;
      --upstream-host)
        UPSTREAM_HOST="$2"
        shift 2
        ;;
      --upstream-port)
        UPSTREAM_PORT="$2"
        shift 2
        ;;
      --cert-mode)
        CERT_MODE="$2"
        shift 2
        ;;
      --email)
        LETSENCRYPT_EMAIL="$2"
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

detect_server_name() {
  if [[ -n "${SERVER_NAME}" ]]; then
    return
  fi

  SERVER_NAME="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "${SERVER_NAME}" ]] || die "Unable to detect server IP automatically."
}

install_packages() {
  log "Installing Nginx and TLS tools..."
  dnf -y install nginx openssl policycoreutils-python-utils >/dev/null

  if [[ "${CERT_MODE}" == "letsencrypt" ]]; then
    dnf -y install certbot python3-certbot-nginx >/dev/null
  fi
}

ensure_selinux_policy() {
  if command_exists getenforce && [[ "$(getenforce)" != "Disabled" ]]; then
    log "Allowing Nginx to connect to upstream service via SELinux policy..."
    setsebool -P httpd_can_network_connect 1 >/dev/null
  fi
}

ensure_firewall() {
  if [[ "${SKIP_FIREWALL}" == "1" ]]; then
    return
  fi

  if systemctl is-active firewalld >/dev/null 2>&1; then
    log "Opening firewall ports 80/tcp and 443/tcp..."
    firewall-cmd --permanent --add-service=http >/dev/null
    firewall-cmd --permanent --add-service=https >/dev/null
    firewall-cmd --reload >/dev/null
  else
    warn "firewalld is not active, skipping firewall changes."
  fi
}

write_http_context_snippet() {
  cat >"${UNDERSCORE_CONF_PATH}" <<'EOF'
underscores_in_headers on;
EOF
}

generate_self_signed_cert() {
  local cert key tmp_cfg san_type san_value

  mkdir -p "${CERT_DIR}"
  cert="${CERT_DIR}/sub2api-selfsigned.crt"
  key="${CERT_DIR}/sub2api-selfsigned.key"
  tmp_cfg="$(mktemp)"

  if [[ "${SERVER_NAME}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    san_type="IP"
  else
    san_type="DNS"
  fi
  san_value="${san_type}.1 = ${SERVER_NAME}"

  cat >"${tmp_cfg}" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
x509_extensions = v3_req
distinguished_name = dn

[dn]
CN = ${SERVER_NAME}

[v3_req]
subjectAltName = @alt_names
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth

[alt_names]
${san_value}
EOF

  log "Generating self-signed certificate for ${SERVER_NAME}..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${key}" \
    -out "${cert}" \
    -config "${tmp_cfg}" >/dev/null 2>&1
  chmod 600 "${key}"
  rm -f "${tmp_cfg}"
}

write_nginx_config_self_signed() {
  cat >"${NGINX_CONF_PATH}" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${SERVER_NAME};

    ssl_certificate ${CERT_DIR}/sub2api-selfsigned.crt;
    ssl_certificate_key ${CERT_DIR}/sub2api-selfsigned.key;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    client_max_body_size 256m;

    proxy_http_version 1.1;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_connect_timeout 60s;

    location / {
        proxy_pass http://${UPSTREAM_HOST}:${UPSTREAM_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF
}

write_nginx_config_plain_http() {
  cat >"${NGINX_CONF_PATH}" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME};

    client_max_body_size 256m;

    proxy_http_version 1.1;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_connect_timeout 60s;

    location / {
        proxy_pass http://${UPSTREAM_HOST}:${UPSTREAM_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF
}

configure_letsencrypt() {
  [[ -n "${LETSENCRYPT_EMAIL}" ]] || die "--email is required when --cert-mode letsencrypt"

  log "Writing temporary HTTP config for Let's Encrypt..."
  write_nginx_config_plain_http
  nginx -t >/dev/null
  systemctl enable --now nginx
  systemctl reload nginx

  log "Requesting Let's Encrypt certificate for ${SERVER_NAME}..."
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --redirect \
    -m "${LETSENCRYPT_EMAIL}" \
    -d "${SERVER_NAME}"
}

configure_self_signed() {
  generate_self_signed_cert
  write_nginx_config_self_signed
}

start_nginx() {
  nginx -t >/dev/null
  systemctl enable --now nginx
  systemctl reload nginx
}

print_summary() {
  printf 'Nginx URL: https://%s\n' "${SERVER_NAME}"
  printf 'Upstream: http://%s:%s\n' "${UPSTREAM_HOST}" "${UPSTREAM_PORT}"
  if [[ "${CERT_MODE}" == "self-signed" ]]; then
    printf 'Certificate: self-signed (%s)\n' "${CERT_DIR}/sub2api-selfsigned.crt"
  else
    printf "Certificate: Let's Encrypt\n"
  fi
}

main() {
  parse_args "$@"
  require_root
  detect_server_name
  install_packages
  ensure_selinux_policy
  ensure_firewall
  write_http_context_snippet

  case "${CERT_MODE}" in
    self-signed)
      configure_self_signed
      start_nginx
      ;;
    letsencrypt)
      configure_letsencrypt
      ;;
    *)
      die "Unsupported cert mode: ${CERT_MODE}"
      ;;
  esac

  print_summary
}

main "$@"
