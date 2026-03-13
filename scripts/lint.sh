#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint is not installed. Install it (e.g. brew install swiftlint) and re-run." >&2
  exit 1
fi

swiftlint lint --config "$REPO_ROOT/.swiftlint.yml"
