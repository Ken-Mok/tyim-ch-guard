#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${HOME}/Library/Application Support/tyim-ch-guard"
BIN="${INSTALL_DIR}/tyim-ch-guard"
LABEL="com.ken.tyim-ch-guard"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"

mkdir -p "${INSTALL_DIR}" "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs"

swiftc -O \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  -o "${BIN}" \
  "${ROOT}/Sources/main.swift"

codesign --force --sign - "${BIN}"

cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${BIN}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>${HOME}/Library/Logs/tyim-ch-guard.log</string>
	<key>StandardErrorPath</key>
	<string>${HOME}/Library/Logs/tyim-ch-guard.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "${PLIST}"
launchctl enable "gui/${UID_NUM}/${LABEL}"
launchctl kickstart -k "gui/${UID_NUM}/${LABEL}"

echo "Installed ${BIN}"
echo "LaunchAgent ${LABEL} is running."
echo "Grant Accessibility to tyim-ch-guard in System Settings > Privacy & Security > Accessibility."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
