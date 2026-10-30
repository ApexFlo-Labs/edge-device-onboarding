#!/usr/bin/env bash
# Install prerequisites, detected accelerator drivers, and OpenSSH; then reboot.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
runner=(bash)
if (( EUID != 0 )); then runner=(sudo bash); fi
printf 'Installing device software...\n'
exec "${runner[@]}" "$SCRIPT_DIR/onboard-device.sh" install --reboot "$@"
