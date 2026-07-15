#!/bin/bash
# Run from Terminal: ./install.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$HOME/Library/Application Support/gemini-local-proxy-bridge"
LABEL="com.example.gemini-local-proxy-bridge"

command -v brew >/dev/null || { echo "Install Homebrew first."; exit 1; }
command -v sing-box >/dev/null || brew install sing-box

mkdir -p "$BASE_DIR"
if [[ ! -f "$BASE_DIR/settings.conf" ]]; then
  cp "$SCRIPT_DIR/settings.conf" "$BASE_DIR/settings.conf"
fi
sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/bridge.sh" > "$BASE_DIR/bridge.sh"
sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/$LABEL.plist" > "$BASE_DIR/$LABEL.plist"
chmod 700 "$BASE_DIR/bridge.sh"

echo "Edit this file before continuing: $BASE_DIR/settings.conf"
echo "Then rerun this installer."
read -r -p "Install the LaunchDaemon now? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || exit 0

sudo install -d -m 755 /usr/local/libexec
sudo install -m 755 "$BASE_DIR/bridge.sh" /usr/local/libexec/gemini-local-proxy-bridge.sh
sudo install -m 644 "$BASE_DIR/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.plist"
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"
sudo launchctl enable "system/$LABEL"
sudo launchctl kickstart -k "system/$LABEL"
echo "Installed. Logs: $BASE_DIR/bridge.log"
