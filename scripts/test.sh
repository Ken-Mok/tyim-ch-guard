#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tyim-ch-guard-tests.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
cat "${ROOT_DIR}/Sources/main.swift" "${ROOT_DIR}/tests/RegressionTests.swift" > "${TEST_DIR}/main.swift"
swiftc -D GUARD_TESTS -module-cache-path "${TEST_DIR}/cache" \
  "${TEST_DIR}/main.swift" -o "${TEST_DIR}/regression-tests"
"${TEST_DIR}/regression-tests"
cat "${ROOT_DIR}/Sources/diagnose.swift" "${ROOT_DIR}/tests/DiagnosticTests.swift" > "${TEST_DIR}/diagnostic-main.swift"
swiftc -D DIAGNOSTIC_TESTS -module-cache-path "${TEST_DIR}/cache" \
  "${TEST_DIR}/diagnostic-main.swift" -o "${TEST_DIR}/diagnostic-tests"
"${TEST_DIR}/diagnostic-tests"
