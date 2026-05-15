#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT_DIR}/scripts/on_device_tc_modules.sh"
bash -n "${ROOT_DIR}/scripts/run_remote_tc_modules.sh"

echo "Shell syntax checks passed."
