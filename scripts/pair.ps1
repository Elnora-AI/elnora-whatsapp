# Foreground pairing for Windows: temporarily stops the keep-alive task, runs
# the bridge in this terminal so the QR code is visible, and restarts the task
# on exit. Run from a regular PowerShell window.
#
# Usage: .\pair.ps1 [-FullHistoryPair]
[CmdletBinding()]
param(
    [string]$Dir = $(if ($env:WHATSAPP_MCP_DIR) { $env:WHATSAPP_MCP_DIR } else { Join-Path $env:USERPROFILE ".whatsapp-mcp" }),
    [switch]$FullHistoryPair
)

$ErrorActionPreference = "Stop"
$BridgeDir = Join-Path $Dir "whatsapp-bridge"
$BridgeBin = Join-Path $BridgeDir "whatsapp-bridge.exe"
$TaskName  = "WhatsApp MCP Bridge"

if (-not (Test-Path $BridgeBin)) {
    Write-Error "Bridge not built at $BridgeDir - run scripts\setup.ps1 first."
    exit 1
}

$restart = $false
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $restart = $true
}

Write-Host "[pair] Running the bridge in the foreground."
Write-Host "[pair] Scan the QR code below with your phone:"
Write-Host "[pair]   WhatsApp > Settings > Linked Devices > Link a Device"
Write-Host "[pair] Each code lasts ~20s; the bridge cycles through 6 before timing out."
Write-Host "[pair] Press Ctrl-C once it prints that it is connected."
Write-Host ""

try {
    Push-Location $BridgeDir
    # Same hardened env the scheduled task uses.
    $env:WEBHOOK_URL  = if ($env:WEBHOOK_URL)  { $env:WEBHOOK_URL }  else { "http://127.0.0.1:9/disabled" }
    $env:FORWARD_SELF = if ($env:FORWARD_SELF) { $env:FORWARD_SELF } else { "false" }
    if ($FullHistoryPair) { & $BridgeBin --full-history-pair } else { & $BridgeBin }
} finally {
    Pop-Location
    if ($restart) {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Host "[pair] Keep-alive task restarted."
    }
}
