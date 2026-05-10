#!/usr/bin/env bash

set -Eeuo pipefail

SSH_HOST="${SSH_HOST:-}"
SSH_USER="${SSH_USER:-root}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
REMOTE_BASE="${REMOTE_BASE:-/opt/sub2api}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@sub2api.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SERVER_PORT="${SERVER_PORT:-18080}"
TZ_VALUE="${TZ_VALUE:-Asia/Shanghai}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
NO_BUILD_CACHE="${NO_BUILD_CACHE:-0}"

usage() {
  cat <<'EOF'
Usage:
  SSH_HOST='SERVER_IP' bash deploy/push-current-to-rocky.sh
  SSH_HOST='SERVER_IP' SSH_PASSWORD='your-password' bash deploy/push-current-to-rocky.sh
  SSH_HOST='SERVER_IP' SSH_KEY_PATH="$HOME/.ssh/id_ed25519" bash deploy/push-current-to-rocky.sh

Optional environment variables:
  SSH_HOST           Required, remote host or IP
  SSH_USER           Default: root
  SSH_PASSWORD       Password mode fallback
  SSH_KEY_PATH       SSH private key path for non-interactive login
  REMOTE_BASE        Default: /opt/sub2api
  ADMIN_EMAIL        Default: admin@sub2api.local
  ADMIN_PASSWORD     Default: empty, app auto-generates it
  SERVER_PORT        Host publish port. Default: 18080
  TZ_VALUE           Default: Asia/Shanghai
  SKIP_FIREWALL      1 to skip firewall changes
  NO_BUILD_CACHE     1 to build without Docker cache
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[INFO] %s\n' "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_tools() {
  [[ -n "${SSH_HOST}" ]] || die "SSH_HOST is required."
  command_exists tar || die "tar is required."
  if [[ -n "${SSH_PASSWORD}" ]]; then
    command_exists expect || die "expect is required when SSH_PASSWORD is set."
  fi
  if [[ -n "${SSH_KEY_PATH}" && ! -f "${SSH_KEY_PATH}" ]]; then
    die "SSH key not found: ${SSH_KEY_PATH}"
  fi
}

quote_remote() {
  printf '%q' "$1"
}

scp_base_cmd() {
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    printf 'scp -i %q' "${SSH_KEY_PATH}"
  else
    printf 'scp'
  fi
}

ssh_base_cmd() {
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    printf 'ssh -i %q' "${SSH_KEY_PATH}"
  else
    printf 'ssh'
  fi
}

expect_copy() {
  local source="$1"
  local target="$2"

  if [[ -n "${SSH_KEY_PATH}" ]]; then
    scp -i "${SSH_KEY_PATH}" "${source}" "${SSH_USER}@${SSH_HOST}:${target}"
    return
  fi

  if [[ -z "${SSH_PASSWORD}" ]]; then
    scp "${source}" "${SSH_USER}@${SSH_HOST}:${target}"
    return
  fi

  env SSH_PASSWORD="${SSH_PASSWORD}" expect <<EOF
set timeout -1
spawn $(scp_base_cmd) ${source} ${SSH_USER}@${SSH_HOST}:${target}
expect {
  -re "yes/no" { send "yes\r"; exp_continue }
  -re "password:" { send "\$env(SSH_PASSWORD)\r"; exp_continue }
  eof
}
catch wait result
exit [lindex \$result 3]
EOF
}

expect_run() {
  local remote_cmd="$1"

  if [[ -n "${SSH_KEY_PATH}" ]]; then
    ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SSH_HOST}" "${remote_cmd}"
    return
  fi

  if [[ -z "${SSH_PASSWORD}" ]]; then
    ssh "${SSH_USER}@${SSH_HOST}" "${remote_cmd}"
    return
  fi

  env SSH_PASSWORD="${SSH_PASSWORD}" expect <<EOF
set timeout -1
spawn $(ssh_base_cmd) ${SSH_USER}@${SSH_HOST} ${remote_cmd}
expect {
  -re "yes/no" { send "yes\r"; exp_continue }
  -re "password:" { send "\$env(SSH_PASSWORD)\r"; exp_continue }
  eof
}
catch wait result
exit [lindex \$result 3]
EOF
}

main() {
  local script_dir repo_root archive_name archive_path staging_dir remote_extract_cmd remote_deploy_cmd remote_cmd

  if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_tools

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  archive_name="sub2api-current-$(date +%Y%m%d%H%M%S).tar.gz"
  archive_path="/tmp/${archive_name}"
  staging_dir="${REMOTE_BASE}/.staging/${archive_name%.tar.gz}"

  log "Packing current repository..."
  COPYFILE_DISABLE=1 tar \
    --exclude=".git" \
    --exclude=".git2" \
    --exclude="sub2api" \
    --exclude="frontend/node_modules" \
    --exclude="deploy/.env" \
    --exclude="deploy/data" \
    --exclude="deploy/postgres_data" \
    --exclude="deploy/redis_data" \
    -czf "${archive_path}" \
    -C "${repo_root}" .

  log "Uploading archive to ${SSH_USER}@${SSH_HOST}..."
  expect_copy "$(quote_remote "${archive_path}")" "$(quote_remote "/tmp/${archive_name}")"

  remote_extract_cmd=$(
    cat <<EOF
set -euo pipefail
mkdir -p $(quote_remote "${REMOTE_BASE}")
mkdir -p $(quote_remote "${REMOTE_BASE}/current") $(quote_remote "${REMOTE_BASE}/.staging")
rm -rf $(quote_remote "${staging_dir}")
mkdir -p $(quote_remote "${staging_dir}")
tar xzf $(quote_remote "/tmp/${archive_name}") -C $(quote_remote "${staging_dir}")
if ! command -v rsync >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install rsync >/dev/null
  else
    echo "rsync is required on the remote host." >&2
    exit 1
  fi
fi
rsync -a --delete \
  --exclude='deploy/.env' \
  --exclude='deploy/data/' \
  --exclude='deploy/postgres_data/' \
  --exclude='deploy/redis_data/' \
  --exclude='data/' \
  --exclude='postgres_data/' \
  --exclude='redis_data/' \
  $(quote_remote "${staging_dir}/") $(quote_remote "${REMOTE_BASE}/current/")
find $(quote_remote "${REMOTE_BASE}/current") -name '._*' -delete
rm -f $(quote_remote "/tmp/${archive_name}")
rm -rf $(quote_remote "${staging_dir}")
EOF
  )

  remote_deploy_cmd="cd $(quote_remote "${REMOTE_BASE}/current") && bash deploy/rocky-deploy.sh --deploy-dir $(quote_remote "${REMOTE_BASE}") --admin-email $(quote_remote "${ADMIN_EMAIL}") --port $(quote_remote "${SERVER_PORT}") --tz $(quote_remote "${TZ_VALUE}")"

  if [[ -n "${ADMIN_PASSWORD}" ]]; then
    remote_deploy_cmd+=" --admin-password $(quote_remote "${ADMIN_PASSWORD}")"
  fi

  if [[ "${SKIP_FIREWALL}" == "1" ]]; then
    remote_deploy_cmd+=" --skip-firewall"
  fi

  if [[ "${NO_BUILD_CACHE}" == "1" ]]; then
    remote_deploy_cmd+=" --no-build-cache"
  fi

  remote_cmd="bash -lc $(quote_remote "${remote_extract_cmd}"$'\n'"${remote_deploy_cmd}")"

  log "Running remote deployment..."
  expect_run "${remote_cmd}"

  log "Remote deployment finished."
  rm -f "${archive_path}"
}

main "$@"
