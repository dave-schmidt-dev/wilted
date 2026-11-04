#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec /usr/bin/python3 "$repo_root/scripts/storage-retention.py" --repo "$repo_root" "$@"
