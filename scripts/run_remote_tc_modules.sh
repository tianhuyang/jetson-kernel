#!/usr/bin/env bash
set -euo pipefail

# Host-side launcher: uploads and runs the on-device build script via SSH.

AUTH_FILE="${1:-auth.env}"
ALLOW_IMAGE_FALLBACK="${2:---allow-image-fallback}"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "ERROR: auth file not found: $AUTH_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$AUTH_FILE"

: "${JETSON_HOST:?JETSON_HOST is required in auth file}"
: "${JETSON_USER:?JETSON_USER is required in auth file}"
: "${JETSON_PASS:?JETSON_PASS is required in auth file}"
JETSON_PORT="${JETSON_PORT:-22}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
	echo "ERROR: required command not found: $1" >&2
	exit 1
  }
}

need_cmd ssh
need_cmd scp

SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
  -p "$JETSON_PORT"
)

if command -v sshpass >/dev/null 2>&1; then
  SSH_PREFIX=(sshpass -p "$JETSON_PASS")
else
  SSH_PREFIX=()
  echo "WARN: sshpass not found; SSH/SCP may prompt for password interactively."
fi

REMOTE_SCRIPT="/tmp/on_device_tc_modules.sh"
LOCAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SCRIPT="${LOCAL_SCRIPT_DIR}/on_device_tc_modules.sh"

if [[ ! -f "$LOCAL_SCRIPT" ]]; then
  echo "ERROR: missing local script: $LOCAL_SCRIPT" >&2
  exit 1
fi

"${SSH_PREFIX[@]}" scp "${SSH_OPTS[@]}" "$LOCAL_SCRIPT" "${JETSON_USER}@${JETSON_HOST}:${REMOTE_SCRIPT}"

# Export password only for non-interactive sudo in the remote script.
REMOTE_CMD="chmod +x ${REMOTE_SCRIPT} && JETSON_PASS=$(printf '%q' "$JETSON_PASS") ${REMOTE_SCRIPT} ${ALLOW_IMAGE_FALLBACK}"
"${SSH_PREFIX[@]}" ssh -tt "${SSH_OPTS[@]}" "${JETSON_USER}@${JETSON_HOST}" "$REMOTE_CMD"

