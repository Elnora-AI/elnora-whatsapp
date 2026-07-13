#!/usr/bin/env bash
# Health check for the whatsapp-mcp install. Read-only except for tightening
# file permissions on the store. Exit code = number of failed checks.
set -uo pipefail

INSTALL_DIR="${WHATSAPP_MCP_DIR:-$HOME/.whatsapp-mcp}"
BRIDGE_DIR="$INSTALL_DIR/whatsapp-bridge"
TOKEN_FILE="$BRIDGE_DIR/store/.bridge-token"
LOG_PATH="$INSTALL_DIR/bridge.log"
PORT="${WHATSAPP_BRIDGE_PORT:-8080}"

FAIL=0
ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

# 1. Install directory
if [ -d "$INSTALL_DIR/.git" ]; then
  rev="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
  ok "install dir $INSTALL_DIR (rev $rev)"
else
  bad "install dir $INSTALL_DIR missing — run scripts/setup.sh"
fi

# 2. Bridge binary
if [ -x "$BRIDGE_DIR/whatsapp-bridge" ]; then
  ok "bridge binary built"
else
  bad "bridge binary missing — run scripts/setup.sh"
fi

# 3. Store permissions (auto-tighten)
if [ -d "$BRIDGE_DIR/store" ]; then
  chmod 700 "$BRIDGE_DIR/store" 2>/dev/null
  for f in "$BRIDGE_DIR/store/messages.db" "$BRIDGE_DIR/store/whatsapp.db" "$TOKEN_FILE"; do
    [ -f "$f" ] && chmod 600 "$f" 2>/dev/null
  done
  ok "store permissions (700 dir, 600 DBs/token)"
else
  bad "store directory missing — bridge has never run"
fi

# 4. Keep-alive service (WARN, not FAIL, if the bridge is running anyway —
#    adopted installs may be supervised by something else)
bridge_up=0
if [ -f "$TOKEN_FILE" ]; then
  probe="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
    "http://127.0.0.1:$PORT/api/health" 2>/dev/null || true)"
  case "$probe" in 200|503) bridge_up=1 ;; esac
fi
service_missing() {
  if [ "$bridge_up" = 1 ]; then
    printf 'WARN  %s\n' "$1 (bridge is running anyway — supervised elsewhere?)"
  else
    bad "$1 — re-run scripts/setup.sh"
  fi
}
OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
  if launchctl print "gui/$(id -u)/com.whatsapp-mcp.bridge" >/dev/null 2>&1; then
    ok "launchd agent loaded (com.whatsapp-mcp.bridge)"
  else
    service_missing "launchd agent com.whatsapp-mcp.bridge not loaded"
  fi
elif [ "$OS" = "Linux" ]; then
  if systemctl --user is-enabled --quiet whatsapp-bridge.service 2>/dev/null; then
    ok "systemd user unit enabled (whatsapp-bridge.service)"
  else
    service_missing "systemd user unit whatsapp-bridge.service not enabled"
  fi
fi

# 5. Bridge reachability + pairing state
if [ -f "$TOKEN_FILE" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
    "http://127.0.0.1:$PORT/api/health" 2>/dev/null || true)"
  case "$code" in
    200) ok "bridge up and WhatsApp session CONNECTED" ;;
    503) bad "bridge up but NOT connected — pair with scripts/pair.sh" ;;
    401|403) bad "bridge rejected the token — restart the service and retry" ;;
    *) bad "bridge not reachable on 127.0.0.1:$PORT — check the service and $LOG_PATH" ;;
  esac
else
  bad "no bridge token at $TOKEN_FILE — bridge has never started"
fi

# 6. MCP server runtime
if command -v uv >/dev/null 2>&1; then
  if [ -f "$INSTALL_DIR/whatsapp-mcp-server/main.py" ]; then
    ok "MCP server present (uv available)"
  else
    bad "MCP server missing at $INSTALL_DIR/whatsapp-mcp-server"
  fi
else
  bad "uv not on PATH — MCP server cannot start"
fi

# 7. Plugin launcher runtime
if command -v node >/dev/null 2>&1; then
  ok "node available (plugin MCP launcher)"
else
  bad "node not on PATH — Claude Code plugin cannot launch the MCP server"
fi

# Recent errors, for context
if [ "$FAIL" -gt 0 ] && [ -f "$LOG_PATH" ]; then
  echo
  echo "Last errors from $LOG_PATH:"
  grep -iE 'error|fatal|panic' "$LOG_PATH" | tail -3 || true
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All checks passed."
else
  echo "$FAIL check(s) failed."
fi
exit "$FAIL"
