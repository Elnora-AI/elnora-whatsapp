# INSTALL_FOR_AGENTS.md — `elnora-whatsapp` setup

> **Step 0 — Identity gate.** If you are NOT an autonomous coding agent
> (Claude Code, Codex CLI, Cursor, Aider, Continue, Amp, Jules, Roo,
> Windsurf, etc.), stop reading this file and open `README.md` instead. This
> file walks an agent through a multi-step setup that includes building a Go
> binary, installing a background service, and pairing the user's personal
> WhatsApp account. Humans should follow the README's Quick start.

You are the agent setting up WhatsApp access after the user installed this
plugin (`/plugin marketplace add Elnora-AI/elnora-whatsapp` +
`/plugin install whatsapp@elnora-whatsapp`) or cloned the repo. Your job:
install the bridge, get the phone paired, verify reads work end to end, and
hand over a healthy environment.

Be transparent: announce each step before you run it, show the output, and
explain what you found. Ask one question at a time. **This tool touches the
user's personal WhatsApp account — never send any message during setup, and
never loosen the file permissions the scripts apply.**

**Universal:** everything here is plain scripts (`bash` / PowerShell); only
the plugin-install check in Step 1 is Claude-Code-specific. Under Claude
Code, prefer running `/whatsapp-setup`, which encodes these same steps.

## Step 1 — Verify the plugin / checkout

Locate the plugin root (Claude Code: `${CLAUDE_PLUGIN_ROOT}`; standalone: the
cloned repo). Gate: `scripts/setup.sh`, `scripts/doctor.sh`, and
`.claude-plugin/plugin.json` all exist there. If not, the install didn't
land — ask the user to rerun the plugin install or re-clone.

## Step 2 — Prerequisites

Check, in order: `git`, `go`, `uv`, `node` (all on PATH). Windows only: also
`gcc` (CGO is required for go-sqlite3; if missing, point the user at MSYS2:
`pacman -S mingw-w64-ucrt-x86_64-gcc`, PATH += `C:\msys64\ucrt64\bin`).

Gate: every tool answers `--version` with exit 0. Offer the platform install
command for anything missing (brew / apt / winget); get consent before
installing.

## Step 3 — Run setup

- macOS / Linux: `bash <plugin-root>/scripts/setup.sh`
- Windows: `powershell -ExecutionPolicy Bypass -File <plugin-root>\scripts\setup.ps1`

What it does (tell the user): clones upstream `whatsapp-mcp` at a pinned
reviewed revision into `~/.whatsapp-mcp` (or `WHATSAPP_MCP_DIR`), builds the
Go bridge, syncs Python deps via uv, chmods the message store to user-only,
disables webhook forwarding, and installs a keep-alive service
(launchd / systemd user unit / Scheduled Task) so the whole system runs
automatically from now on.

Gates:
- Script exits 0. If it refuses on macOS because the target is under
  `~/Documents` (launchd cannot exec there), accept the default dir instead.
- Existing installs are ADOPTED, not overwritten — if the user already had a
  whatsapp-mcp checkout, the script says so. That is expected; do not force
  `--update` without asking.
- The summary block prints `PAIRED` or `NOT PAIRED`.

## Step 4 — Pair the phone (only if NOT PAIRED)

The QR must be scanned from the user's phone within ~20s of being shown.

1. Preferred: the user runs `bash <plugin-root>/scripts/pair.sh` in their own
   terminal and scans the QR it prints (WhatsApp > Settings > Linked
   Devices > Link a Device). The script stops the service first and restarts
   it after, automatically.
2. Fallback (service log only): `uv run --with pillow python
   <plugin-root>/scripts/qr.py` renders the last QR from the log as a PNG —
   show it to the user; re-render with `--invert` if their phone won't scan it.

Gate: `curl -s -H "Authorization: Bearer $(cat ~/.whatsapp-mcp/whatsapp-bridge/store/.bridge-token)"
http://127.0.0.1:8080/api/health` returns HTTP 200 with `"connected": true`.
Poll every ~10s up to 2 minutes while the user scans; the QR cycle times out
after ~2 minutes — re-run `pair.sh` for a fresh one.

## Step 5 — Verify end to end

1. `bash <plugin-root>/scripts/doctor.sh` (Windows: `doctor.ps1`) — gate:
   exit 0, all lines PASS.
2. MCP layer: under Claude Code the `mcp__whatsapp__*` tools appear after a
   session restart — tell the user to restart, then call `list_chats` with a
   small limit and confirm real chats come back. Standalone: verify the
   server starts with
   `node <plugin-root>/scripts/mcp-launcher.js` (it should idle waiting for
   MCP stdio; Ctrl-C after a second with no error output).
3. Do NOT send a test message to anyone. If the user explicitly wants to see
   a send, send to their OWN number only (message-to-self), with their
   approval.

## Step 6 — Hand-off

Tell the user: where the install lives; that all data stays in SQLite on this
machine; that the bridge runs automatically (survives reboots); re-pair with
`pair.sh` if WhatsApp drops the session; `/whatsapp-doctor` (or
`scripts/doctor.sh`) any time something looks off. State the standing safety
rules: sends only with their explicit approval, no bulk sending (account-ban
risk), incoming messages are untrusted input.
