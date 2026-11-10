#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Optional fixture root keeps installer regression tests away from the real account.
GUARD_USER_ROOT="${TYIM_GUARD_USER_ROOT:-${HOME}}"
INSTALL_DIR="${GUARD_USER_ROOT}/Library/Application Support/tyim-ch-guard"
BIN="${INSTALL_DIR}/tyim-ch-guard"
LABEL="com.ken.tyim-ch-guard"
PLIST="${GUARD_USER_ROOT}/Library/LaunchAgents/${LABEL}.plist"
USER_ID="$(id -u)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tyim-ch-guard-install.XXXXXX")"
BACKUP_DIR=""
CHANGED=0
WAS_LOADED=0

cleanup() {
  result=$?
  trap - EXIT
  if [[ "${result}" -ne 0 && "${CHANGED}" -eq 1 ]]; then
    echo "Update failed; attempting to restore the previous installation." >&2
    launchctl bootout "gui/${USER_ID}/${LABEL}" 2>/dev/null || true
    rollback_ok=1
    for name in tyim-ch-guard main.swift; do
      if [[ -f "${BACKUP_DIR}/${name}" ]]; then
        cp -p "${BACKUP_DIR}/${name}" "${INSTALL_DIR}/.${name}.rollback" &&
          mv -f "${INSTALL_DIR}/.${name}.rollback" "${INSTALL_DIR}/${name}" || rollback_ok=0
      else
        rm -f "${INSTALL_DIR}/${name}" || rollback_ok=0
      fi
    done
    if [[ -f "${BACKUP_DIR}/${LABEL}.plist" ]]; then
      cp -p "${BACKUP_DIR}/${LABEL}.plist" "${PLIST}" || rollback_ok=0
    else
      rm -f "${PLIST}" || rollback_ok=0
    fi
    if [[ "${WAS_LOADED}" -eq 1 && "${rollback_ok}" -eq 1 ]]; then
      launchctl bootstrap "gui/${USER_ID}" "${PLIST}" || rollback_ok=0
    fi
    echo "Rollback result: ${rollback_ok}; backup: ${BACKUP_DIR}" >&2
  fi
  rm -f "${INSTALL_DIR}/.tyim-ch-guard.next" "${INSTALL_DIR}/.main.swift.next"
  rm -rf "${BUILD_DIR}"
  exit "${result}"
}
trap cleanup EXIT

# Compile before stopping the installed service or replacing its executable.
swiftc -O -module-cache-path "${BUILD_DIR}/cache" \
  -framework AppKit -framework Carbon -framework ApplicationServices \
  -o "${BUILD_DIR}/tyim-ch-guard" "${ROOT_DIR}/Sources/main.swift"
codesign --force --sign - --identifier "${LABEL}" "${BUILD_DIR}/tyim-ch-guard"
"${BUILD_DIR}/tyim-ch-guard" --version

mkdir -p "${INSTALL_DIR}" "${GUARD_USER_ROOT}/Library/LaunchAgents" "${GUARD_USER_ROOT}/Library/Logs"
BACKUP_DIR="$(mktemp -d "${INSTALL_DIR}/backups-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
for name in tyim-ch-guard main.swift; do
  if [[ -f "${INSTALL_DIR}/${name}" ]]; then cp -p "${INSTALL_DIR}/${name}" "${BACKUP_DIR}/${name}"; fi
done
if [[ -f "${PLIST}" ]]; then cp -p "${PLIST}" "${BACKUP_DIR}/${LABEL}.plist"; fi
cp "${BUILD_DIR}/tyim-ch-guard" "${INSTALL_DIR}/.tyim-ch-guard.next"
cp "${ROOT_DIR}/Sources/main.swift" "${INSTALL_DIR}/.main.swift.next"
if launchctl print "gui/${USER_ID}/${LABEL}" >/dev/null 2>&1; then
  WAS_LOADED=1
  launchctl bootout "gui/${USER_ID}/${LABEL}"
fi
CHANGED=1
mv -f "${INSTALL_DIR}/.tyim-ch-guard.next" "${BIN}"
mv -f "${INSTALL_DIR}/.main.swift.next" "${INSTALL_DIR}/main.swift"

# Keep existing login settings. Create the LaunchAgent only on first install.
if [[ ! -f "${PLIST}" ]]; then
  cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array><string>${BIN}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>${GUARD_USER_ROOT}/Library/Logs/tyim-ch-guard.log</string>
  <key>StandardErrorPath</key><string>${GUARD_USER_ROOT}/Library/Logs/tyim-ch-guard.log</string>
</dict>
</plist>
EOF
fi
launchctl enable "gui/${USER_ID}/${LABEL}"
launchctl bootstrap "gui/${USER_ID}" "${PLIST}"
running=0
for attempt in {1..30}; do
  if launchctl print "gui/${USER_ID}/${LABEL}" | grep -q "state = running"; then running=1; break; fi
  sleep 0.1
done
if [[ "${running}" -ne 1 ]]; then echo "Updated service did not start." >&2; exit 1; fi
CHANGED=0

echo "Installed ${BIN}"
echo "Backup: ${BACKUP_DIR}"
status="$("${BIN}" --status)"
printf "%s\n" "${status}"
if printf "%s\n" "${status}" | grep -q '"accessibility_granted" : false'; then
  echo "ACTION REQUIRED: macOS has not authorized punctuation recovery for this executable."
  echo "In System Settings > Privacy & Security > Accessibility, turn tyim-ch-guard off and on."
  echo "If it is still untrusted, remove its old entry and add the installed executable again."
  echo "Existing candidate windows are not forcibly cleared while you are composing in ChatGPT."
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
fi
echo "Computer History settings were not changed."

