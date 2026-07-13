#!/usr/bin/env bash
# Foreground pairing: temporarily stops the keep-alive service, runs the bridge
# in this terminal so the QR code is visible, and restarts the service on exit.
#
# Usage: pair.sh [--full-history-pair]
#   --full-history-pair  Request full message history at pair time (only
#                        effective on a fresh pair, i.e. store/whatsapp.db absent).
set -euo pipefail

INSTALL_DIR="${WHATSAPP_MCP_DIR:-$HOME/.whatsapp-mcp}"
BRIDGE_DIR="$INSTALL_DIR/whatsapp-bridge"

[ -x "$BRIDGE_DIR/whatsapp-bridge" ] || {
  echo "[pair] Bridge not built at $BRIDGE_DIR — run scripts/setup.sh first." >&2
  exit 1
}

OS="$(uname -s)"
restart=0
if [ "$OS" = "Darwin" ]; then
  if launchctl print "gui/$(id -u)/com.whatsapp-mcp.bridge" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/com.whatsapp-mcp.bridge" 2>/dev/null || true
    restart=1
  fi
elif [ "$OS" = "Linux" ]; then
  # is-enabled, not is-active: an unpaired bridge exits cleanly after the QR
  # window (~15 min) and Restart=on-failure won't have revived it — the unit
  # still needs restarting after a successful pair.
  if systemctl --user is-enabled --quiet whatsapp-bridge.service 2>/dev/null; then
    systemctl --user stop whatsapp-bridge.service 2>/dev/null || true
    restart=1
  fi
fi

cleanup() {
  if [ "$restart" = 1 ]; then
    if [ "$OS" = "Darwin" ]; then
      launchctl bootstrap "gui/$(id -u)" \
        "$HOME/Library/LaunchAgents/com.whatsapp-mcp.bridge.plist" 2>/dev/null || true
    else
      systemctl --user start whatsapp-bridge.service 2>/dev/null || true
    fi
    echo "[pair] Keep-alive service restarted."
  fi
}
trap cleanup EXIT

echo "[pair] Running the bridge in the foreground."
echo "[pair] Scan the QR code below with your phone:"
echo "[pair]   WhatsApp > Settings > Linked Devices > Link a Device"
echo "[pair] Each code lasts ~20s; the bridge cycles through 6 before timing out."
echo "[pair] Press Ctrl-C once it prints that it is connected."
echo

cd "$BRIDGE_DIR"
WEBHOOK_URL="${WEBHOOK_URL:-http://127.0.0.1:9/disabled}" \
FORWARD_SELF="${FORWARD_SELF:-false}" \
  ./whatsapp-bridge "$@"
