#!/usr/bin/env bash

set -Eeuo pipefail

SSH_HOST="${SSH_HOST:-}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SERVER_NAME="${SERVER_NAME:-${SSH_HOST}}"
UPSTREAM_HOST="${UPSTREAM_HOST:-127.0.0.1}"
UPSTREAM_PORT="${UPSTREAM_PORT:-8080}"
CERT_MODE="${CERT_MODE:-self-signed}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[INFO] %s\n' "$*"
}

quote_remote() {
  printf '%q' "$1"
}

usage() {
  cat <<'EOF'
Usage:
  SSH_HOST='SERVER_IP' SSH_KEY_PATH="$HOME/.ssh/sub2api_rocky" bash deploy/push-nginx-to-rocky.sh

Optional environment variables:
  SSH_HOST            Required, remote host or IP
  SSH_USER            Default: root
  SSH_KEY_PATH        SSH private key path
  SERVER_NAME         Domain or IP for Nginx. Default: SSH_HOST
  UPSTREAM_HOST       Default: 127.0.0.1
  UPSTREAM_PORT       Default: 8080
  CERT_MODE           self-signed or letsencrypt. Default: self-signed
  LETSENCRYPT_EMAIL   Required when CERT_MODE=letsencrypt
  SKIP_FIREWALL       1 to skip firewalld changes
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ -n "${SSH_HOST}" ]] || die "SSH_HOST is required."
[[ -n "${SSH_KEY_PATH}" ]] || die "SSH_KEY_PATH is required."
[[ -f "${SSH_KEY_PATH}" ]] || die "SSH key not found: ${SSH_KEY_PATH}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
remote_script="/tmp/rocky-nginx-https.sh"

log "Uploading Nginx HTTPS deploy script..."
scp -i "${SSH_KEY_PATH}" "${script_dir}/rocky-nginx-https.sh" "${SSH_USER}@${SSH_HOST}:${remote_script}"

remote_cmd="bash $(quote_remote "${remote_script}") --server-name $(quote_remote "${SERVER_NAME}") --upstream-host $(quote_remote "${UPSTREAM_HOST}") --upstream-port $(quote_remote "${UPSTREAM_PORT}") --cert-mode $(quote_remote "${CERT_MODE}")"
if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
  remote_cmd+=" --email $(quote_remote "${LETSENCRYPT_EMAIL}")"
fi
if [[ "${SKIP_FIREWALL}" == "1" ]]; then
  remote_cmd+=" --skip-firewall"
fi
remote_cmd+=" && rm -f $(quote_remote "${remote_script}")"

log "Running remote Nginx HTTPS deployment..."
ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SSH_HOST}" "${remote_cmd}"
