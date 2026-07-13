@echo off
rem Rendered by scripts/setup.ps1 — starts the WhatsApp bridge with hardened env.
rem Webhook forwarding disabled by default (see launchd template for rationale).
set "WEBHOOK_URL={{WEBHOOK_URL}}"
set "FORWARD_SELF={{FORWARD_SELF}}"
cd /d "{{BRIDGE_DIR}}"
"{{BRIDGE_BIN}}" >> "{{LOG_PATH}}" 2>&1
