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

: "${VPN_PROCESS_PATTERN:?Set VPN_PROCESS_PATTERN in settings.conf}"
: "${VPN_SOCKS_HOST:?Set VPN_SOCKS_HOST in settings.conf}"
: "${VPN_SOCKS_PORT:?Set VPN_SOCKS_PORT in settings.conf}"
: "${VPN_HEALTHCHECK_URL:=https://www.gstatic.com/generate_204}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

stop_bridge() {
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ -n "$pid" && "$command" == "$SING_BOX run -c $CONFIG"* ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      # Give sing-box a moment to remove its TUN interface and routes. A
      # disconnected VPN must never leave a TUN that points at a dead SOCKS.
      for _ in {1..10}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
      if kill -0 "$pid" 2>/dev/null; then
        log "sing-box did not exit after SIGTERM; forcing cleanup"
        kill -KILL "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$PID_FILE"
}

# A listening port is not sufficient: some clients keep accepting SOCKS
# connections while their upstream is already unusable. Test a real HTTPS
# request through SOCKS and fail closed when the exit is unhealthy.
socks_is_healthy() {
  lsof -nP -iTCP@"$VPN_SOCKS_HOST":"$VPN_SOCKS_PORT" -sTCP:LISTEN \
    >/dev/null 2>&1 || return 1
  curl --silent --show-error --output /dev/null \
    --socks5-hostname "$VPN_SOCKS_HOST:$VPN_SOCKS_PORT" \
    --connect-timeout 1 --max-time 2 "$VPN_HEALTHCHECK_URL" \
    >/dev/null 2>&1
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
      NR > 1 && $9 ~ /->/ && $10 == "(ESTABLISHED)" {
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
  # Do not exclude 172.16.0.0/12: the TUN itself uses 172.19.0.1/30.
  addresses='"10.0.0.0/8", "169.254.0.0/16", "192.168.0.0/16"'
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
  log "Bridge started"
}

trap 'stop_bridge; log "Bridge service stopped"' EXIT INT TERM
log "Bridge service started"
health_failures=0

while true; do
  endpoints="$(get_vpn_endpoints || true)"
  socks_healthy=false
  socks_is_healthy && socks_healthy=true
  if [[ "$socks_healthy" == true ]]; then
    health_failures=0
  else
    health_failures=$((health_failures + 1))
  fi

  if [[ -z "$endpoints" || "$health_failures" -ge 2 ]]; then
    if [[ -f "$PID_FILE" ]]; then
      if [[ "$health_failures" -ge 2 ]]; then
        log "SOCKS exit is unhealthy; stopping bridge before VPN reconnect"
      else
        log "VPN has no upstream endpoint; stopping bridge"
      fi
      stop_bridge
    fi
    # Do not reuse an endpoint captured before the VPN disconnected.
    rm -f "$STATE"
  elif [[ "$socks_healthy" != true ]]; then
    : # Ignore one transient probe failure; do not start or rebuild the TUN.
  elif [[ ! -f "$STATE" ]] || ! diff -q <(printf '%s\n' "$endpoints") "$STATE" >/dev/null; then
    printf '%s\n' "$endpoints" > "$STATE"
    start_bridge
  elif [[ ! -f "$PID_FILE" ]] || ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    log "Bridge exited; restarting"
    start_bridge
  fi
  sleep 3
done
