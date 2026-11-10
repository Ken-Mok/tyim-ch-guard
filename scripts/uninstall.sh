#!/usr/bin/env bash
set -euo pipefail

LABEL="com.ken.tyim-ch-guard"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
INSTALL_DIR="${HOME}/Library/Application Support/tyim-ch-guard"
UID_NUM="$(id -u)"

launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
rm -f "${PLIST}"
rm -rf "${INSTALL_DIR}"

echo "Removed ${LABEL} and ${INSTALL_DIR}"
echo "You can also remove Accessibility permission for tyim-ch-guard if present."
