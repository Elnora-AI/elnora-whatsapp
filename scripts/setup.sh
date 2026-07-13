#!/usr/bin/env bash
# elnora-whatsapp setup — clone, build, harden, and keep the WhatsApp bridge
# running automatically. macOS (launchd) + Linux (systemd --user).
# Windows: use scripts/setup.ps1 instead.
set -euo pipefail

UPSTREAM_REPO="https://github.com/verygoodplugins/whatsapp-mcp.git"
# Known-good upstream revision. Override with --ref at your own risk.
PINNED_REF="e5f1a9aef5c78198ad27d52d40d4513d3b7e0e2f"

INSTALL_DIR="${WHATSAPP_MCP_DIR:-$HOME/.whatsapp-mcp}"
# Default: webhook forwarding disabled. The bridge has no off switch — an unset
# WEBHOOK_URL makes it POST every incoming message to localhost:8769, where any
# local process could listen. Port 9 is root-only to bind, so this discards.
WEBHOOK_URL_VALUE="http://127.0.0.1:9/disabled"
FORWARD_SELF_VALUE="false"
INSTALL_SERVICE=1
UPDATE=0
REF_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: setup.sh [options]

  --dir <path>      Install location (default: $WHATSAPP_MCP_DIR or ~/.whatsapp-mcp)
  --webhook <url>   Forward incoming messages to this URL (default: disabled)
  --no-service      Clone + build only; skip the keep-alive service
  --update          Move an existing checkout to the pinned revision
  --ref <ref>       Use a specific upstream ref instead of the pinned one
  -h, --help        Show this help

Idempotent: safe to re-run. An existing checkout (including one made by hand
before this plugin existed) is adopted as-is unless you pass --update.
EOF
}

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        INSTALL_DIR="$2"; shift 2 ;;
    --webhook)    WEBHOOK_URL_VALUE="$2"; shift 2 ;;
    --no-service) INSTALL_SERVICE=0; shift ;;
    --update)     UPDATE=1; shift ;;
    --ref)        REF_OVERRIDE="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "Unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$REF_OVERRIDE" ] && PINNED_REF="$REF_OVERRIDE"

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  *) die "Unsupported OS '$OS'. On Windows, run scripts/setup.ps1." ;;
esac

# --- prerequisites -----------------------------------------------------------
missing=()
command -v git  >/dev/null 2>&1 || missing+=("git")
command -v go   >/dev/null 2>&1 || missing+=("go (https://go.dev/dl/)")
command -v uv   >/dev/null 2>&1 || missing+=("uv (https://docs.astral.sh/uv/)")
command -v curl >/dev/null 2>&1 || missing+=("curl")
if [ "${#missing[@]}" -gt 0 ]; then
  die "Missing prerequisites: ${missing[*]}"
fi
command -v node >/dev/null 2>&1 || \
  warn "node not found — the Claude Code plugin's MCP launcher needs it (https://nodejs.org)."

# macOS TCC: launchd cannot exec binaries under ~/Documents, ~/Desktop,
# ~/Downloads (no Full Disk Access) — the service would silently fail.
if [ "$OS" = "Darwin" ] && [ "$INSTALL_SERVICE" = 1 ]; then
  case "$INSTALL_DIR" in
    "$HOME/Documents"*|"$HOME/Desktop"*|"$HOME/Downloads"*)
      warn "On macOS, launchd cannot start binaries under ~/Documents, ~/Desktop, or ~/Downloads."
      warn "Use a different --dir (the default ~/.whatsapp-mcp works), or pass --no-service."
      die  "Refusing to install a keep-alive service that cannot start."
      ;;
  esac
fi

# --- clone or adopt ----------------------------------------------------------
if [ ! -d "$INSTALL_DIR/.git" ]; then
  log "Cloning whatsapp-mcp into $INSTALL_DIR"
  git clone --quiet "$UPSTREAM_REPO" "$INSTALL_DIR"
  git -C "$INSTALL_DIR" checkout --quiet "$PINNED_REF"
else
  current="$(git -C "$INSTALL_DIR" rev-parse HEAD)"
  if [ "$current" = "$PINNED_REF" ]; then
    log "Existing checkout already at the pinned revision."
  elif [ "$UPDATE" = 1 ]; then
    [ -z "$(git -C "$INSTALL_DIR" status --porcelain)" ] || \
      die "Checkout at $INSTALL_DIR has local changes; refusing to --update."
    log "Updating checkout to $PINNED_REF"
    git -C "$INSTALL_DIR" fetch --quiet origin
    git -C "$INSTALL_DIR" checkout --quiet "$PINNED_REF"
  else
    warn "Adopting existing checkout at ${current:0:12} (pinned: ${PINNED_REF:0:12})."
    warn "Pass --update to move it to the pinned revision."
  fi
fi

BRIDGE_DIR="$INSTALL_DIR/whatsapp-bridge"
BRIDGE_BIN="$BRIDGE_DIR/whatsapp-bridge"
LOG_PATH="$INSTALL_DIR/bridge.log"

# --- build -------------------------------------------------------------------
log "Building the Go bridge (first build downloads modules — may take a minute)"
(cd "$BRIDGE_DIR" && go build -o whatsapp-bridge .)

log "Syncing MCP server dependencies (uv)"
(cd "$INSTALL_DIR/whatsapp-mcp-server" && uv sync --quiet)

# --- harden ------------------------------------------------------------------
mkdir -p "$BRIDGE_DIR/store"
chmod 700 "$BRIDGE_DIR/store"
for f in "$BRIDGE_DIR/store/messages.db" "$BRIDGE_DIR/store/whatsapp.db" \
         "$BRIDGE_DIR/store/.bridge-token"; do
  [ -f "$f" ] && chmod 600 "$f"
done

# --- keep-alive service ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"

render() {
  sed -e "s|{{BRIDGE_BIN}}|$BRIDGE_BIN|g" \
      -e "s|{{BRIDGE_DIR}}|$BRIDGE_DIR|g" \
      -e "s|{{WEBHOOK_URL}}|$WEBHOOK_URL_VALUE|g" \
      -e "s|{{FORWARD_SELF}}|$FORWARD_SELF_VALUE|g" \
      -e "s|{{LOG_PATH}}|$LOG_PATH|g" \
      "$1"
}

if [ "$INSTALL_SERVICE" = 1 ]; then
  if [ "$OS" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.whatsapp-mcp.bridge.plist"
    log "Installing launchd agent com.whatsapp-mcp.bridge"
    mkdir -p "$HOME/Library/LaunchAgents"
    render "$TEMPLATE_DIR/launchd/com.whatsapp-mcp.bridge.plist" > "$PLIST"
    launchctl bootout "gui/$(id -u)/com.whatsapp-mcp.bridge" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  else
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    log "Installing systemd user unit whatsapp-bridge.service"
    mkdir -p "$UNIT_DIR"
    render "$TEMPLATE_DIR/systemd/whatsapp-bridge.service" > "$UNIT_DIR/whatsapp-bridge.service"
    systemctl --user daemon-reload
    systemctl --user enable --now whatsapp-bridge.service
    command -v loginctl >/dev/null 2>&1 && ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes' && \
      warn "Tip: 'loginctl enable-linger $USER' keeps the bridge running when you are logged out."
  fi
else
  warn "Skipping keep-alive service (--no-service). Run the bridge manually:"
  warn "  cd $BRIDGE_DIR && WEBHOOK_URL='$WEBHOOK_URL_VALUE' FORWARD_SELF='$FORWARD_SELF_VALUE' ./whatsapp-bridge"
fi

# --- pairing status ----------------------------------------------------------
status="unknown"
if [ "$INSTALL_SERVICE" = 1 ]; then
  log "Waiting for the bridge to come up..."
  TOKEN_FILE="$BRIDGE_DIR/store/.bridge-token"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    [ -f "$TOKEN_FILE" ] || continue
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
      http://127.0.0.1:8080/api/health || true)"
    case "$code" in
      200) status="paired"; break ;;
      503) status="unpaired"; break ;;
    esac
  done
  [ -f "$TOKEN_FILE" ] && chmod 600 "$TOKEN_FILE"
fi

# --- summary -----------------------------------------------------------------
echo
log "Install directory : $INSTALL_DIR"
log "Bridge binary     : $BRIDGE_BIN"
log "Bridge log        : $LOG_PATH"
log "Message store     : $BRIDGE_DIR/store/ (chmod 700, DBs 600 — never share or commit)"
log "Webhook forwarding: $WEBHOOK_URL_VALUE"
case "$status" in
  paired)
    log "WhatsApp session  : PAIRED and connected — you're done."
    ;;
  unpaired)
    log "WhatsApp session  : NOT PAIRED yet."
    log "Next: run scripts/pair.sh — it shows a QR code in your terminal;"
    log "scan it from your phone (WhatsApp > Settings > Linked Devices)."
    ;;
  *)
    if [ "$INSTALL_SERVICE" = 1 ]; then
      warn "Bridge did not come up within 20s — check $LOG_PATH, then run scripts/doctor.sh."
    else
      log "Next: start the bridge (see above), then pair via the QR it prints."
    fi
    ;;
esac
if [ "$INSTALL_DIR" != "$HOME/.whatsapp-mcp" ] && [ "${WHATSAPP_MCP_DIR:-}" != "$INSTALL_DIR" ]; then
  log "Non-default directory: export WHATSAPP_MCP_DIR=\"$INSTALL_DIR\" so the MCP launcher finds it."
fi
