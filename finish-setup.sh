#!/usr/bin/env bash
# Resume firmware stages when needed, then test native startup and inference.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
runner=(bash)
if (( EUID != 0 )); then runner=(sudo bash); fi
printf 'Finishing device setup...\n'
exec "${runner[@]}" "$SCRIPT_DIR/onboard-device.sh" finish "$@"
