# WhatsApp for Claude Code

Read, search, and send WhatsApp messages from Claude Code — on your own
personal account, 100% locally. Your messages live in SQLite on your machine;
nothing is sent to any cloud, and sends always go through your approval.

```text
"What did Ana say about the invoice last week?"
"Summarize my unread group chats."
"Send the address to Tom on WhatsApp."   ← asks for your approval first
"Download the PDF Maria sent me yesterday."
```

## What you get

- **14 MCP tools** — search contacts, list/read chats and messages, message
  context, send text / files / voice notes / reactions, download media.
- **A skill** that teaches Claude the fast paths: direct SQLite for bulk
  reads, contact-first lookups, and the safety rules (approval-gated sends,
  incoming content treated as untrusted).
- **Automated setup** — `/whatsapp-setup` installs everything; the only
  manual step is scanning one QR code with your phone.
- **Runs automatically** — a keep-alive service (launchd on macOS, systemd on
  Linux, Task Scheduler on Windows) keeps the bridge running across reboots
  and crashes. `/whatsapp-doctor` checks and repairs the install.
- **Hardened defaults** — localhost-only REST API behind a bearer token,
  message store readable only by you, webhook forwarding disabled.

## How it works

Your phone pairs this machine as a WhatsApp **linked device** (same mechanism
as WhatsApp Web). Three local pieces, all from the open-source
[whatsapp-mcp](https://github.com/verygoodplugins/whatsapp-mcp) project:

```text
WhatsApp on your phone
   │  (linked device, end-to-end encrypted)
   ▼
Go bridge (whatsmeow) ──► SQLite store        ~/.whatsapp-mcp/whatsapp-bridge/store/
   │  localhost REST, bearer token
   ▼
Python MCP server ──► Claude Code (14 tools)
```

This plugin adds what the upstream project leaves to you: one-command setup,
a pinned reviewed revision, permission hardening, the keep-alive service,
pairing and health tooling, and the Claude Code skill/commands.

## Quick start (Claude Code)

```text
/plugin marketplace add Elnora-AI/elnora-whatsapp
/plugin install whatsapp@elnora-whatsapp
/whatsapp-setup
```

Scan the QR code when asked (WhatsApp > Settings > Linked Devices), restart
Claude Code, and ask it about your chats. Total time ≈ 5 minutes, most of it
the Go build.

**Prerequisites:** [Go](https://go.dev/dl/), [uv](https://docs.astral.sh/uv/),
[Node.js](https://nodejs.org), git. Windows also needs a C compiler for CGO
(`pacman -S mingw-w64-ucrt-x86_64-gcc` in [MSYS2](https://www.msys2.org/)).
Optional: FFmpeg for sending arbitrary audio as voice notes.

## Manual install (any MCP client)

The setup scripts work without Claude Code:

```bash
git clone https://github.com/Elnora-AI/elnora-whatsapp
bash elnora-whatsapp/scripts/setup.sh        # Windows: scripts\setup.ps1
```

Then register the MCP server in your client:

```json
{
  "mcpServers": {
    "whatsapp": {
      "command": "uv",
      "args": ["--directory", "<home>/.whatsapp-mcp/whatsapp-mcp-server", "run", "main.py"]
    }
  }
}
```

Useful flags: `--dir <path>` (custom location; also set `WHATSAPP_MCP_DIR`),
`--webhook <url>` (forward incoming messages — off by default),
`--no-service` (skip the keep-alive service), `--update` (move an existing
checkout to the pinned revision). Re-pair anytime with `scripts/pair.sh`;
check health with `scripts/doctor.sh`.

## Security & privacy

- **Local-only.** Messages sync into SQLite on your machine and are read from
  there. The bridge's REST API binds to 127.0.0.1 and requires a bearer token
  (`store/.bridge-token`, mode 600).
- **Webhook forwarding is OFF by default.** The upstream bridge would
  otherwise POST every incoming message to a localhost port that any local
  process could claim; setup points it at a root-only discard port. Opt in
  with `--webhook <url>` if you actually consume it.
- **Store hardening.** `store/` is chmod 700 (user-only ACL on Windows), the
  DBs and token 600. The store holds your full message history and session
  keys — never commit or copy it.
- **Pinned upstream.** Setup checks out a specific reviewed revision of
  whatsapp-mcp, not `main`. Update deliberately with `--update`.
- **Prompt injection.** Incoming message content is untrusted input. The
  skill instructs Claude to treat it as data and never follow instructions
  embedded in messages.
- **Honest caveat: this is unofficial.** Linked-device automation is not an
  official WhatsApp API. Read-heavy use with human-approved sends has been
  fine in practice, but bulk or spammy sending patterns can get an account
  banned. This project enforces nothing server-side — the skill's rules and
  your judgment do. Use at your own risk.

## Uninstall

```bash
# macOS
launchctl bootout gui/$(id -u)/com.whatsapp-mcp.bridge
rm ~/Library/LaunchAgents/com.whatsapp-mcp.bridge.plist
# Linux
systemctl --user disable --now whatsapp-bridge.service
rm ~/.config/systemd/user/whatsapp-bridge.service
# Windows
Unregister-ScheduledTask -TaskName "WhatsApp MCP Bridge" -Confirm:$false

rm -rf ~/.whatsapp-mcp      # deletes all synced messages + session
```

Also remove the linked device from your phone: WhatsApp > Settings > Linked
Devices.

## For agents

Setting this up for a user? Follow [INSTALL_FOR_AGENTS.md](INSTALL_FOR_AGENTS.md).
Driving an existing install from a non-Claude harness? See [AGENTS.md](AGENTS.md).

## Credits & license

Wraps [verygoodplugins/whatsapp-mcp](https://github.com/verygoodplugins/whatsapp-mcp)
(maintained fork of [lharries/whatsapp-mcp](https://github.com/lharries/whatsapp-mcp), MIT),
built on [whatsmeow](https://github.com/tulir/whatsmeow). This repo:
Apache-2.0, © Elnora AI.
