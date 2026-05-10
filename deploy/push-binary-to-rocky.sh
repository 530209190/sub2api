#!/usr/bin/env bash

set -Eeuo pipefail

SSH_HOST="${SSH_HOST:-}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
REMOTE_BASE="${REMOTE_BASE:-/opt/sub2api-binary}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@sub2api.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SERVER_PORT="${SERVER_PORT:-8080}"
TZ_VALUE="${TZ_VALUE:-Asia/Shanghai}"
DB_NAME="${DB_NAME:-sub2api}"
DB_USER="${DB_USER:-sub2api}"
DB_PASSWORD="${DB_PASSWORD:-}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
NPM_CONFIG_REGISTRY="${NPM_CONFIG_REGISTRY:-https://registry.npmmirror.com}"
GOPROXY_VALUE="${GOPROXY_VALUE:-https://goproxy.cn,direct}"
GOSUMDB_VALUE="${GOSUMDB_VALUE:-sum.golang.google.cn}"
BUILD_ROOT=""

log() {
  printf '[INFO] %s\n' "$*"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  SSH_HOST='SERVER_IP' SSH_KEY_PATH="$HOME/.ssh/sub2api_rocky" bash deploy/push-binary-to-rocky.sh

Optional environment variables:
  SSH_HOST           Required, remote host or IP
  SSH_USER           Default: root
  SSH_KEY_PATH       SSH private key path
  SSH_PASSWORD       Password mode fallback
  ADMIN_EMAIL        Default: admin@sub2api.local
  ADMIN_PASSWORD     Default: auto-generated on remote
  SERVER_PORT        Default: 8080
  TZ_VALUE           Default: Asia/Shanghai
  DB_NAME            Default: sub2api
  DB_USER            Default: sub2api
  DB_PASSWORD        Default: auto-generated on remote
  SKIP_FIREWALL      1 to skip firewalld changes
  NPM_CONFIG_REGISTRY Default: https://registry.npmmirror.com
  GOPROXY_VALUE      Default: https://goproxy.cn,direct
  GOSUMDB_VALUE      Default: sum.golang.google.cn
EOF
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

quote_remote() {
  printf '%q' "$1"
}

require_tools() {
  [[ -n "${SSH_HOST}" ]] || die "SSH_HOST is required."
  command_exists tar || die "tar is required."
  command_exists go || die "go is required."
  command_exists npm || die "npm is required."
  if [[ -n "${SSH_KEY_PATH}" && ! -f "${SSH_KEY_PATH}" ]]; then
    die "SSH key not found: ${SSH_KEY_PATH}"
  fi
  if [[ -n "${SSH_PASSWORD}" ]]; then
    command_exists expect || die "expect is required when SSH_PASSWORD is set."
  fi
}

ssh_cmd() {
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    ssh -i "${SSH_KEY_PATH}" "$@"
  else
    ssh "$@"
  fi
}

scp_cmd() {
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    scp -i "${SSH_KEY_PATH}" "$@"
  else
    scp "$@"
  fi
}

run_remote() {
  local remote_cmd="$1"

  if [[ -n "${SSH_KEY_PATH}" || -z "${SSH_PASSWORD}" ]]; then
    ssh_cmd "${SSH_USER}@${SSH_HOST}" "${remote_cmd}"
    return
  fi

  env SSH_PASSWORD="${SSH_PASSWORD}" expect <<EOF
set timeout -1
spawn ssh ${SSH_USER}@${SSH_HOST} ${remote_cmd}
expect {
  -re "yes/no" { send "yes\r"; exp_continue }
  -re "password:" { send "\$env(SSH_PASSWORD)\r"; exp_continue }
  eof
}
catch wait result
exit [lindex \$result 3]
EOF
}

copy_remote() {
  local src="$1"
  local dst="$2"

  if [[ -n "${SSH_KEY_PATH}" || -z "${SSH_PASSWORD}" ]]; then
    scp_cmd "${src}" "${SSH_USER}@${SSH_HOST}:${dst}"
    return
  fi

  env SSH_PASSWORD="${SSH_PASSWORD}" expect <<EOF
set timeout -1
spawn scp ${src} ${SSH_USER}@${SSH_HOST}:${dst}
expect {
  -re "yes/no" { send "yes\r"; exp_continue }
  -re "password:" { send "\$env(SSH_PASSWORD)\r"; exp_continue }
  eof
}
catch wait result
exit [lindex \$result 3]
EOF
}

run_pnpm() {
  if command_exists pnpm; then
    npm_config_registry="${NPM_CONFIG_REGISTRY}" pnpm "$@"
  else
    npm_config_registry="${NPM_CONFIG_REGISTRY}" npx --yes pnpm@10.18.2 "$@"
  fi
}

build_artifact() {
  local repo_root="$1"
  local build_root="$2"
  local version commit date_value local_go_version

  log "Preparing isolated build workspace..."
  mkdir -p "${build_root}/src"
  tar \
    --exclude=".git" \
    --exclude=".git2" \
    --exclude="sub2api" \
    --exclude="frontend/node_modules" \
    --exclude="deploy/.env" \
    --exclude="deploy/data" \
    --exclude="deploy/postgres_data" \
    --exclude="deploy/redis_data" \
    -cf - -C "${repo_root}" . | tar -xf - -C "${build_root}/src"

  log "Building frontend..."
  (
    cd "${build_root}/src/frontend"
    run_pnpm install --frozen-lockfile
    run_pnpm build
  )

  if [[ -d "${build_root}/src/frontend/dist" ]]; then
    rm -rf "${build_root}/src/backend/internal/web/dist"
    cp -R "${build_root}/src/frontend/dist" "${build_root}/src/backend/internal/web/dist"
  elif [[ -d "${build_root}/src/backend/internal/web/dist" ]]; then
    :
  else
    die "Frontend build output not found."
  fi

  version="$(tr -d '\r\n' < "${build_root}/src/backend/cmd/server/VERSION")"
  commit="$(git -C "${repo_root}" rev-parse --short HEAD 2>/dev/null || echo local)"
  date_value="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local_go_version="$(go env GOVERSION | sed 's/^go//')"

  if [[ -n "${local_go_version}" ]]; then
    perl -0pi -e "s/^go\s+1\.26\.2$/go ${local_go_version}/m" "${build_root}/src/backend/go.mod"
  fi

  log "Building Linux binary..."
  (
    cd "${build_root}/src/backend"
    GOTOOLCHAIN=local GOPROXY="${GOPROXY_VALUE}" GOSUMDB="${GOSUMDB_VALUE}" CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -tags embed \
      -ldflags="-s -w -X main.Version=${version} -X main.Commit=${commit} -X main.Date=${date_value} -X main.BuildType=source" \
      -trimpath \
      -o "${build_root}/artifact/sub2api" \
      ./cmd/server
  )

  mkdir -p "${build_root}/artifact/resources"
  cp -R "${build_root}/src/backend/resources/." "${build_root}/artifact/resources/"
}

main() {
  local script_dir repo_root artifact_path remote_artifact remote_script remote_cmd

  if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_tools
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  BUILD_ROOT="$(mktemp -d)"
  artifact_path="${BUILD_ROOT}/sub2api-binary.tar.gz"
  remote_artifact="/tmp/sub2api-binary.tar.gz"
  remote_script="/tmp/rocky-binary-deploy.sh"

  trap '[[ -n "${BUILD_ROOT}" ]] && rm -rf "${BUILD_ROOT}"' EXIT

  build_artifact "${repo_root}" "${BUILD_ROOT}"

  log "Packing artifact..."
  tar -czf "${artifact_path}" -C "${BUILD_ROOT}/artifact" .

  log "Uploading artifact and deploy script..."
  copy_remote "${artifact_path}" "${remote_artifact}"
  copy_remote "${repo_root}/deploy/rocky-binary-deploy.sh" "${remote_script}"

  remote_cmd="bash $(quote_remote "${remote_script}") --artifact $(quote_remote "${remote_artifact}") --admin-email $(quote_remote "${ADMIN_EMAIL}") --port $(quote_remote "${SERVER_PORT}") --tz $(quote_remote "${TZ_VALUE}") --db-name $(quote_remote "${DB_NAME}") --db-user $(quote_remote "${DB_USER}")"

  if [[ -n "${ADMIN_PASSWORD}" ]]; then
    remote_cmd+=" --admin-password $(quote_remote "${ADMIN_PASSWORD}")"
  fi
  if [[ -n "${DB_PASSWORD}" ]]; then
    remote_cmd+=" --db-password $(quote_remote "${DB_PASSWORD}")"
  fi
  if [[ "${SKIP_FIREWALL}" == "1" ]]; then
    remote_cmd+=" --skip-firewall"
  fi
  remote_cmd+=" && rm -f $(quote_remote "${remote_artifact}") $(quote_remote "${remote_script}")"

  log "Running remote binary deployment..."
  run_remote "${remote_cmd}"
}

main "$@"
