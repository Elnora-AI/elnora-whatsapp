---
description: Check the health of the WhatsApp bridge and MCP server, and fix what's broken
---

Diagnose the WhatsApp install and repair it.

1. Run the platform doctor script:
   - macOS / Linux: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"`
   - Windows: `powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}\scripts\doctor.ps1"`
2. Show the user the PASS/FAIL lines and explain any failures in plain
   language.
3. Fix what failed, with the user's consent:
   - Install dir or binary missing → re-run setup (`/whatsapp-setup`).
   - Service not loaded → re-run the setup script (it re-installs the service
     idempotently).
   - Bridge up but NOT connected → the session needs re-pairing: user runs
     `bash "${CLAUDE_PLUGIN_ROOT}/scripts/pair.sh"` in their terminal and
     scans the QR (WhatsApp > Settings > Linked Devices).
   - Bridge not reachable → check the log the doctor points at; the last
     error lines it prints usually name the cause (port in use, crash loop).
   - `uv`/`node` missing → offer the platform install command.
4. Re-run the doctor until everything passes, then confirm to the user that
   reads AND sends are healthy (health endpoint returns `"connected": true`).
