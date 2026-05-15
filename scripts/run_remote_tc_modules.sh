#!/usr/bin/env bash
set -euo pipefail

# Host-side launcher: uploads and runs the on-device build script via SSH.

AUTH_FILE="${1:-auth.env}"
ALLOW_IMAGE_FALLBACK="${2:-}"

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
JETSON_HTTPS_PROXY="${JETSON_HTTPS_PROXY:-}"
JETSON_L4T_TAG="${JETSON_L4T_TAG:-}"

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

SCP_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
  -P "$JETSON_PORT"
)

USE_SSHPASS=0
if command -v sshpass >/dev/null 2>&1; then
  USE_SSHPASS=1
else
  echo "WARN: sshpass not found; SSH/SCP may prompt for password interactively."
fi

REMOTE_SCRIPT="/tmp/on_device_tc_modules.sh"
REMOTE_SOURCE_SYNC="/tmp/source_sync.sh"
LOCAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SCRIPT="${LOCAL_SCRIPT_DIR}/on_device_tc_modules.sh"
LOCAL_SOURCE_SYNC="${LOCAL_SCRIPT_DIR}/source_sync.sh"

if [[ ! -f "$LOCAL_SCRIPT" ]]; then
  echo "ERROR: missing local script: $LOCAL_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$LOCAL_SOURCE_SYNC" ]]; then
  echo "ERROR: missing local script: $LOCAL_SOURCE_SYNC" >&2
  exit 1
fi

if [[ "$USE_SSHPASS" -eq 1 ]]; then
  sshpass -p "$JETSON_PASS" scp "${SCP_OPTS[@]}" "$LOCAL_SCRIPT" "${JETSON_USER}@${JETSON_HOST}:${REMOTE_SCRIPT}"
  sshpass -p "$JETSON_PASS" scp "${SCP_OPTS[@]}" "$LOCAL_SOURCE_SYNC" "${JETSON_USER}@${JETSON_HOST}:${REMOTE_SOURCE_SYNC}"
else
  scp "${SCP_OPTS[@]}" "$LOCAL_SCRIPT" "${JETSON_USER}@${JETSON_HOST}:${REMOTE_SCRIPT}"
  scp "${SCP_OPTS[@]}" "$LOCAL_SOURCE_SYNC" "${JETSON_USER}@${JETSON_HOST}:${REMOTE_SOURCE_SYNC}"
fi

# Export password only for non-interactive sudo in the remote script.
REMOTE_ENV="JETSON_PASS=$(printf '%q' "$JETSON_PASS")"
if [[ -n "$JETSON_HTTPS_PROXY" ]]; then
  REMOTE_ENV+=" https_proxy=$(printf '%q' "$JETSON_HTTPS_PROXY")"
  REMOTE_ENV+=" HTTPS_PROXY=$(printf '%q' "$JETSON_HTTPS_PROXY")"
  REMOTE_ENV+=" http_proxy=$(printf '%q' "$JETSON_HTTPS_PROXY")"
  REMOTE_ENV+=" HTTP_PROXY=$(printf '%q' "$JETSON_HTTPS_PROXY")"
fi
if [[ -n "$JETSON_L4T_TAG" ]]; then
  REMOTE_ENV+=" JETSON_L4T_TAG=$(printf '%q' "$JETSON_L4T_TAG")"
fi

REMOTE_CMD="chmod +x ${REMOTE_SCRIPT} ${REMOTE_SOURCE_SYNC} && ${REMOTE_ENV} ${REMOTE_SCRIPT}"
if [[ -n "$ALLOW_IMAGE_FALLBACK" ]]; then
  REMOTE_CMD+=" ${ALLOW_IMAGE_FALLBACK}"
fi
if [[ "$USE_SSHPASS" -eq 1 ]]; then
  sshpass -p "$JETSON_PASS" ssh -tt "${SSH_OPTS[@]}" "${JETSON_USER}@${JETSON_HOST}" "$REMOTE_CMD"
else
  ssh -tt "${SSH_OPTS[@]}" "${JETSON_USER}@${JETSON_HOST}" "$REMOTE_CMD"
fi

