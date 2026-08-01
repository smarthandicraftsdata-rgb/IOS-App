#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mapfile -t files < <(find "$ROOT/iosApp/SHLAMP" -name '*.swift' -print | sort)
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is not installed; skipping parser validation."
  exit 0
fi
swiftc -parse "${files[@]}"
echo "Swift parser validation passed for ${#files[@]} files."
