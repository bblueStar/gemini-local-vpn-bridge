#!/bin/bash
# Runs as root from a LaunchDaemon. Edit settings.conf before installing.
set -euo pipefail

BASE_DIR="__HOME__/Library/Application Support/gemini-local-proxy-bridge"
SETTINGS="$BASE_DIR/settings.conf"
SING_BOX="/opt/homebrew/bin/sing-box"
CONFIG="$BASE_DIR/sing-box.json"
STATE="$BASE_DIR/endpoints.txt"
PID_FILE="$BASE_DIR/sing-box.pid"
LOG="$BASE_DIR/bridge.log"

mkdir -p "$BASE_DIR"
# shellcheck source=/dev/null
source "$SETTINGS"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

stop_bridge() {
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
  fi
  rm -f "$PID_FILE"
}

# Only keep connections opened from the real LAN interface. This avoids
# mistaking proxied application traffic for the VPN's own upstream server.
get_vpn_endpoints() {
  pids="$(pgrep -f "$VPN_PROCESS_PATTERN" || true)"
  [[ -n "$pids" ]] || return 0
  interface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  local_ip="$(ipconfig getifaddr "$interface" 2>/dev/null || true)"
  [[ -n "$local_ip" ]] || return 0

  for pid in $pids; do
    lsof -nP -a -p "$pid" -iTCP 2>/dev/null | awk -v local_ip="$local_ip" '
      NR > 1 && $9 ~ /->/ {
        split($9, pair, "->")
        if (pair[1] !~ ("^" local_ip ":")) next
        remote = pair[2]
        sub(/:[0-9]+$/, "", remote)
        if (remote !~ /^127\./ && remote !~ /^10\./ && remote !~ /^192\.168\./ && remote !~ /^192\.0\.0\./ && remote !~ /^169\.254\./ && remote !~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./ && remote !~ /^\[/ && remote !~ /^::1$/) print remote
      }
    '
  done | sort -u
}

write_config() {
  addresses='"192.168.0.0/16"'
  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] && addresses="$addresses, \"$endpoint/32\""
  done < "$STATE"

  cat > "$CONFIG.tmp" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [{
    "type": "tun",
    "address": ["172.19.0.1/30"],
    "auto_route": true,
    "strict_route": true,
    "route_exclude_address": [$addresses],
    "stack": "mixed"
  }],
  "outbounds": [{
    "type": "socks",
    "tag": "vpn_local_socks",
    "server": "$VPN_SOCKS_HOST",
    "server_port": $VPN_SOCKS_PORT,
    "version": "5"
  }],
  "route": { "auto_detect_interface": true, "final": "vpn_local_socks" }
}
EOF
  mv "$CONFIG.tmp" "$CONFIG"
  "$SING_BOX" check -c "$CONFIG"
}

start_bridge() {
  stop_bridge
  write_config
  "$SING_BOX" run -c "$CONFIG" >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$PID_FILE"
  log "Bridge started for $(tr '\n' ' ' < "$STATE")"
}

trap 'stop_bridge; log "Bridge service stopped"' EXIT INT TERM
log "Bridge service started"

while true; do
  endpoints="$(get_vpn_endpoints || true)"
  if [[ -z "$endpoints" ]]; then
    if [[ -f "$PID_FILE" ]]; then
      log "VPN is not connected; stopping bridge"
      stop_bridge
      rm -f "$STATE"
    fi
  elif [[ ! -f "$STATE" ]] || ! diff -q <(printf '%s\n' "$endpoints") "$STATE" >/dev/null; then
    printf '%s\n' "$endpoints" > "$STATE"
    start_bridge
  elif [[ ! -f "$PID_FILE" ]] || ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    log "Bridge exited; restarting"
    start_bridge
  fi
  sleep 2
done
