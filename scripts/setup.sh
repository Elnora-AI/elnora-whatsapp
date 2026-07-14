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
PORT_VALUE="8080"
INSTALL_SERVICE=1
UPDATE=0
REF_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: setup.sh [options]

  --dir <path>      Install location (default: $WHATSAPP_MCP_DIR or ~/.whatsapp-mcp)
  --webhook <url>   Forward incoming messages to this URL (default: disabled)
  --port <n>        Bridge REST port (default: 8080)
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
    --port)       PORT_VALUE="$2"; shift 2 ;;
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

# --- input validation --------------------------------------------------------
# These values are substituted into service files; keep them boring.
# NB: a literal newline variable — $(printf '\n') strips to empty and would
# match every string.
NL='
'
case "$INSTALL_DIR" in
  *'|'*|*'<'*|*'>'*|*'"'*|*"$NL"*) die "Install dir contains unsupported characters." ;;
esac
case "$WEBHOOK_URL_VALUE" in
  *'|'*|*'<'*|*'>'*|*'"'*|*"'"*|*' '*|*"$NL"*) die "--webhook URL contains unsupported characters." ;;
esac
case "$PORT_VALUE" in
  ''|*[!0-9]*) die "--port must be a number." ;;
esac

# Canonicalize so rendered service files always hold an absolute path.
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"

# --- prerequisites -----------------------------------------------------------
missing=()
command -v git  >/dev/null 2>&1 || missing+=("git")
command -v go   >/dev/null 2>&1 || missing+=("go (https://go.dev/dl/)")
command -v uv   >/dev/null 2>&1 || missing+=("uv (https://docs.astral.sh/uv/)")
command -v curl >/dev/null 2>&1 || missing+=("curl")
if [ "$OS" = "Linux" ]; then
  # go-sqlite3 needs CGO, which needs a C compiler.
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || \
    missing+=("a C compiler (apt install build-essential / dnf group install c-development)")
fi
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
    # Fetch from the pinned repo URL, not 'origin' — adopted checkouts may
    # point at a different remote (e.g. the original lharries fork).
    git -C "$INSTALL_DIR" fetch --quiet "$UPSTREAM_REPO" "$PINNED_REF"
    git -C "$INSTALL_DIR" checkout --quiet FETCH_HEAD
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
# The bridge logs every message (sender + full body) to stdout, which the
# services below redirect into bridge.log. Lock down the whole install dir and
# pre-create the log 600 so no other local user can read the transcript.
chmod 700 "$INSTALL_DIR"
touch "$LOG_PATH"
chmod 600 "$LOG_PATH"
mkdir -p "$BRIDGE_DIR/store"
chmod 700 "$BRIDGE_DIR/store"
for f in "$BRIDGE_DIR/store/messages.db" "$BRIDGE_DIR/store/whatsapp.db" \
         "$BRIDGE_DIR/store/.bridge-token"; do
  [ -f "$f" ] && chmod 600 "$f"
done

# --- keep-alive service ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"

# Escape a value for use in a sed replacement (backslash, &, and the | delimiter).
sed_escape() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }
# Escape a value for embedding in XML (plist).
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

render() { # $1 = template path, $2 = "xml" | "plain"
  local wh="$WEBHOOK_URL_VALUE"
  if [ "$2" = "xml" ]; then wh="$(xml_escape "$wh")"; fi
  sed -e "s|{{BRIDGE_BIN}}|$(sed_escape "$BRIDGE_BIN")|g" \
      -e "s|{{BRIDGE_DIR}}|$(sed_escape "$BRIDGE_DIR")|g" \
      -e "s|{{WEBHOOK_URL}}|$(sed_escape "$wh")|g" \
      -e "s|{{FORWARD_SELF}}|$FORWARD_SELF_VALUE|g" \
      -e "s|{{BRIDGE_PORT}}|$PORT_VALUE|g" \
      -e "s|{{LOG_PATH}}|$(sed_escape "$LOG_PATH")|g" \
      "$1"
}

if [ "$INSTALL_SERVICE" = 1 ]; then
  if [ "$OS" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.whatsapp-mcp.bridge.plist"
    log "Installing launchd agent com.whatsapp-mcp.bridge"
    mkdir -p "$HOME/Library/LaunchAgents"
    render "$TEMPLATE_DIR/launchd/com.whatsapp-mcp.bridge.plist" xml > "$PLIST"
    launchctl bootout "gui/$(id -u)/com.whatsapp-mcp.bridge" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  else
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    log "Installing systemd user unit whatsapp-bridge.service"
    mkdir -p "$UNIT_DIR"
    render "$TEMPLATE_DIR/systemd/whatsapp-bridge.service" plain > "$UNIT_DIR/whatsapp-bridge.service"
    systemctl --user daemon-reload
    systemctl --user enable --now whatsapp-bridge.service
    command -v loginctl >/dev/null 2>&1 && ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes' && \
      warn "Tip: 'loginctl enable-linger $USER' keeps the bridge running when you are logged out."
  fi
else
  warn "Skipping keep-alive service (--no-service). Run the bridge manually:"
  warn "  cd $BRIDGE_DIR && WEBHOOK_URL='$WEBHOOK_URL_VALUE' FORWARD_SELF='$FORWARD_SELF_VALUE' WHATSAPP_BRIDGE_PORT='$PORT_VALUE' ./whatsapp-bridge"
fi

# --- pairing status ----------------------------------------------------------
# Note: the bridge only opens its REST port once a WhatsApp session exists, so
# on a truly fresh install the health check stays unreachable and the QR
# banner in the log is the "not paired" signal.
status="unknown"
if [ "$INSTALL_SERVICE" = 1 ]; then
  log "Waiting for the bridge to come up..."
  TOKEN_FILE="$BRIDGE_DIR/store/.bridge-token"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    [ -f "$TOKEN_FILE" ] || continue
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
      "http://127.0.0.1:$PORT_VALUE/api/health" || true)"
    case "$code" in
      200) status="paired"; break ;;
      503) status="unpaired"; break ;;
    esac
  done
  if [ "$status" = "unknown" ] && [ -s "$LOG_PATH" ] && \
     grep -q -e "Scan this QR code" -e "Waiting for QR code scan" "$LOG_PATH"; then
    status="unpaired"
  fi
  [ -f "$TOKEN_FILE" ] && chmod 600 "$TOKEN_FILE"
fi

# --- summary -----------------------------------------------------------------
echo
log "Install directory : $INSTALL_DIR (chmod 700)"
log "Bridge binary     : $BRIDGE_BIN"
log "Bridge log        : $LOG_PATH (chmod 600 — contains message content)"
log "Message store     : $BRIDGE_DIR/store/ (chmod 700, DBs 600 — never share or commit)"
log "Webhook forwarding: $WEBHOOK_URL_VALUE"
case "$status" in
  paired)
    log "WhatsApp session  : PAIRED and connected — you're done."
    ;;
  unpaired)
    log "WhatsApp session  : NOT PAIRED yet (expected on first install)."
    log "Next: run scripts/pair.sh — it shows a QR code in your terminal;"
    log "scan it from your phone (WhatsApp > Settings > Linked Devices)."
    ;;
  *)
    if [ "$INSTALL_SERVICE" = 1 ]; then
      warn "Bridge state unclear after 20s — check $LOG_PATH, then run scripts/doctor.sh."
    else
      log "Next: start the bridge (see above), then pair via the QR it prints."
    fi
    ;;
esac
if [ "$INSTALL_DIR" != "$HOME/.whatsapp-mcp" ] && [ "${WHATSAPP_MCP_DIR:-}" != "$INSTALL_DIR" ]; then
  log "Non-default directory: export WHATSAPP_MCP_DIR=\"$INSTALL_DIR\" so the MCP launcher finds it."
fi
if [ "$PORT_VALUE" != "8080" ]; then
  log "Non-default port: export WHATSAPP_BRIDGE_PORT=$PORT_VALUE and"
  log "WHATSAPP_API_URL=\"http://localhost:$PORT_VALUE/api\" so the MCP server and doctor find the bridge."
fi
