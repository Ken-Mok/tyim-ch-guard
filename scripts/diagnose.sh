#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIAGNOSTIC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tyim-ch-guard-diagnostic.XXXXXX")"
trap 'rm -rf "${DIAGNOSTIC_DIR}"' EXIT
swiftc -module-cache-path "${DIAGNOSTIC_DIR}/cache" \
  "${ROOT_DIR}/Sources/diagnose.swift" -o "${DIAGNOSTIC_DIR}/diagnose"
"${DIAGNOSTIC_DIR}/diagnose"
