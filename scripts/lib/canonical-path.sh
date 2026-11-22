#!/usr/bin/env bash

wilted_canonical_path() {
  local helper="${BASH_SOURCE[0]%/*}/canonical_path.py"
  python3 "$helper" "$1"
}
