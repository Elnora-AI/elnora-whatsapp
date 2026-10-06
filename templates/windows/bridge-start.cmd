@echo off
rem Rendered by scripts/setup.ps1 — starts the WhatsApp bridge with hardened env.
rem Webhook forwarding disabled by default (see launchd template for rationale).
set "WEBHOOK_ENABLED={{WEBHOOK_ENABLED}}"
set "WEBHOOK_URL={{WEBHOOK_URL}}"
set "FORWARD_SELF={{FORWARD_SELF}}"
set "WHATSAPP_BRIDGE_PORT={{BRIDGE_PORT}}"
cd /d "{{BRIDGE_DIR}}"
rem Restart on every exit: the bridge exits 0 when it gives up connecting,
rem which the scheduled task does not count as a failure.
:run
"{{BRIDGE_BIN}}" >> "{{LOG_PATH}}" 2>&1
ping -n 31 127.0.0.1 >nul
goto run
