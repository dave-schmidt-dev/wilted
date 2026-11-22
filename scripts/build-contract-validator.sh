#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <validator.swift> <output-path>" >&2
  exit 2
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(basename "$1")" in
  validate-contract-fixtures.swift|validate-domain-contract.swift)
    validator_source="$root_dir/scripts/$(basename "$1")"
    ;;
  *)
    echo "error: unsupported contract validator: $1" >&2
    exit 2
    ;;
esac

build_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/contract-validator.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
cp "$validator_source" "$build_dir/main.swift"
swiftc "$root_dir/scripts/lib/contract-validation-common.swift" "$build_dir/main.swift" -o "$2"
