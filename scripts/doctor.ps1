# Health check for the whatsapp-mcp install on Windows.
# Read-only. Exit code = number of failed checks.
[CmdletBinding()]
param(
    [string]$Dir = $(if ($env:WHATSAPP_MCP_DIR) { $env:WHATSAPP_MCP_DIR } else { Join-Path $env:USERPROFILE ".whatsapp-mcp" })
)

$ErrorActionPreference = "SilentlyContinue"
$BridgeDir = Join-Path $Dir "whatsapp-bridge"
$TokenFile = Join-Path $BridgeDir "store\.bridge-token"
$LogPath   = Join-Path $Dir "bridge.log"
$TaskName  = "WhatsApp MCP Bridge"
$Port      = if ($env:WHATSAPP_BRIDGE_PORT) { $env:WHATSAPP_BRIDGE_PORT } else { "8080" }

$script:Fail = 0
function OK([string]$msg)  { Write-Host "PASS  $msg" }
function Bad([string]$msg) { Write-Host "FAIL  $msg"; $script:Fail++ }

if (Test-Path (Join-Path $Dir ".git")) {
    $rev = (git -C $Dir rev-parse --short HEAD 2>$null)
    OK "install dir $Dir (rev $rev)"
} else { Bad "install dir $Dir missing - run scripts\setup.ps1" }

if (Test-Path (Join-Path $BridgeDir "whatsapp-bridge.exe")) { OK "bridge binary built" }
else { Bad "bridge binary missing - run scripts\setup.ps1" }

$bridgeUp = $false
if (Test-Path $TokenFile) {
    try {
        $probeToken = (Get-Content $TokenFile -Raw).Trim()
        Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" `
            -Headers @{ Authorization = "Bearer $probeToken" } -UseBasicParsing | Out-Null
        $bridgeUp = $true
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 503) { $bridgeUp = $true }
    }
}
$task = Get-ScheduledTask -TaskName $TaskName 2>$null
if ($task) { OK "scheduled task registered ('$TaskName', state: $($task.State))" }
elseif ($bridgeUp) { Write-Host "WARN  scheduled task '$TaskName' not registered (bridge is running anyway - supervised elsewhere?)" }
else { Bad "scheduled task '$TaskName' not registered - re-run scripts\setup.ps1" }

if (Test-Path $TokenFile) {
    $token = (Get-Content $TokenFile -Raw).Trim()
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" `
            -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing | Out-Null
        OK "bridge up and WhatsApp session CONNECTED"
    } catch {
        $codeNum = 0
        if ($_.Exception.Response) { $codeNum = [int]$_.Exception.Response.StatusCode }
        if ($codeNum -eq 503) { Bad "bridge up but NOT connected - run the bridge in a terminal and scan the QR" }
        elseif ($codeNum -eq 401 -or $codeNum -eq 403) { Bad "bridge rejected the token - restart the task and retry" }
        else { Bad "bridge not reachable on 127.0.0.1:$Port - check the task and $LogPath" }
    }
} else { Bad "no bridge token at $TokenFile - bridge has never started" }

if (Get-Command uv -ErrorAction SilentlyContinue) {
    if (Test-Path (Join-Path $Dir "whatsapp-mcp-server\main.py")) { OK "MCP server present (uv available)" }
    else { Bad "MCP server missing at $Dir\whatsapp-mcp-server" }
} else { Bad "uv not on PATH - MCP server cannot start" }

if (Get-Command node -ErrorAction SilentlyContinue) { OK "node available (plugin MCP launcher)" }
else { Bad "node not on PATH - Claude Code plugin cannot launch the MCP server" }

Write-Host ""
if ($script:Fail -eq 0) { Write-Host "All checks passed." }
else { Write-Host "$($script:Fail) check(s) failed." }
exit $script:Fail
