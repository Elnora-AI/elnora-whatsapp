# elnora-whatsapp setup for Windows — clone, build, harden, and keep the
# WhatsApp bridge running automatically via Task Scheduler.
# macOS/Linux: use scripts/setup.sh instead.
#
# Usage: .\setup.ps1 [-Dir <path>] [-Webhook <url>] [-NoService] [-Update] [-Ref <ref>]
[CmdletBinding()]
param(
    [string]$Dir = $(if ($env:WHATSAPP_MCP_DIR) { $env:WHATSAPP_MCP_DIR } else { Join-Path $env:USERPROFILE ".whatsapp-mcp" }),
    [string]$Webhook = "http://127.0.0.1:9/disabled",
    [switch]$NoService,
    [switch]$Update,
    [string]$Ref = ""
)

$ErrorActionPreference = "Stop"

$UpstreamRepo = "https://github.com/verygoodplugins/whatsapp-mcp.git"
# Known-good upstream revision. Override with -Ref at your own risk.
$PinnedRef = "e5f1a9aef5c78198ad27d52d40d4513d3b7e0e2f"
if ($Ref) { $PinnedRef = $Ref }
$ForwardSelf = "false"
$TaskName = "WhatsApp MCP Bridge"

function Log([string]$msg)  { Write-Host "[setup] $msg" -ForegroundColor Green }
function Warn([string]$msg) { Write-Host "[setup] $msg" -ForegroundColor Yellow }
function Die([string]$msg)  { Write-Host "[setup] $msg" -ForegroundColor Red; exit 1 }

# --- prerequisites -----------------------------------------------------------
$missing = @()
foreach ($tool in @("git", "go", "uv")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $missing += $tool }
}
if ($missing.Count -gt 0) {
    Die ("Missing prerequisites: " + ($missing -join ", ") + ". Install git (git-scm.com), Go (go.dev/dl), uv (docs.astral.sh/uv).")
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Warn "node not found - the Claude Code plugin's MCP launcher needs it (nodejs.org)."
}
# go-sqlite3 needs CGO, which needs a C compiler on Windows.
if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
    Warn "gcc not found. The bridge build needs CGO (go-sqlite3)."
    Warn "Install MSYS2 (msys2.org), then in an MSYS2 shell: pacman -S mingw-w64-ucrt-x86_64-gcc"
    Warn "and add C:\msys64\ucrt64\bin to your PATH. Then re-run this script."
    Die "C compiler required."
}

# --- clone or adopt ----------------------------------------------------------
if (-not (Test-Path (Join-Path $Dir ".git"))) {
    Log "Cloning whatsapp-mcp into $Dir"
    git clone --quiet $UpstreamRepo $Dir
    git -C $Dir checkout --quiet $PinnedRef
} else {
    $current = (git -C $Dir rev-parse HEAD).Trim()
    if ($current -eq $PinnedRef) {
        Log "Existing checkout already at the pinned revision."
    } elseif ($Update) {
        $dirty = git -C $Dir status --porcelain
        if ($dirty) { Die "Checkout at $Dir has local changes; refusing to -Update." }
        Log "Updating checkout to $PinnedRef"
        git -C $Dir fetch --quiet origin
        git -C $Dir checkout --quiet $PinnedRef
    } else {
        Warn "Adopting existing checkout at $($current.Substring(0,12)) (pinned: $($PinnedRef.Substring(0,12))). Pass -Update to switch."
    }
}

$BridgeDir = Join-Path $Dir "whatsapp-bridge"
$BridgeBin = Join-Path $BridgeDir "whatsapp-bridge.exe"
$LogPath   = Join-Path $Dir "bridge.log"

# --- build -------------------------------------------------------------------
Log "Building the Go bridge (CGO enabled; first build may take a few minutes)"
Push-Location $BridgeDir
try {
    $env:CGO_ENABLED = "1"
    go build -o whatsapp-bridge.exe .
} finally { Pop-Location }

Log "Syncing MCP server dependencies (uv)"
Push-Location (Join-Path $Dir "whatsapp-mcp-server")
try { uv sync --quiet } finally { Pop-Location }

# --- harden ------------------------------------------------------------------
$Store = Join-Path $BridgeDir "store"
New-Item -ItemType Directory -Force -Path $Store | Out-Null
# Restrict the store to the current user (best-effort NTFS ACL).
try {
    icacls $Store /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" | Out-Null
} catch {
    Warn "Could not tighten ACLs on $Store - do this manually if the machine is shared."
}

# --- keep-alive scheduled task -----------------------------------------------
if (-not $NoService) {
    $TemplatePath = Join-Path $PSScriptRoot "..\templates\windows\bridge-start.cmd"
    $StartCmd = Join-Path $Dir "bridge-start.cmd"
    (Get-Content $TemplatePath -Raw) `
        -replace '\{\{BRIDGE_BIN\}\}', $BridgeBin `
        -replace '\{\{BRIDGE_DIR\}\}', $BridgeDir `
        -replace '\{\{WEBHOOK_URL\}\}', $Webhook `
        -replace '\{\{FORWARD_SELF\}\}', $ForwardSelf `
        -replace '\{\{LOG_PATH\}\}', $LogPath |
        Set-Content -Path $StartCmd -Encoding ASCII

    Log "Registering scheduled task '$TaskName' (runs at logon, restarts on failure)"
    $action   = New-ScheduledTaskAction -Execute $StartCmd
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet `
        -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
    Start-ScheduledTask -TaskName $TaskName
} else {
    Warn "Skipping keep-alive task (-NoService). Run the bridge manually:"
    Warn "  cd $BridgeDir; `$env:WEBHOOK_URL='$Webhook'; `$env:FORWARD_SELF='$ForwardSelf'; .\whatsapp-bridge.exe"
}

# --- pairing status ----------------------------------------------------------
$status = "unknown"
if (-not $NoService) {
    Log "Waiting for the bridge to come up..."
    $TokenFile = Join-Path $Store ".bridge-token"
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 2
        if (-not (Test-Path $TokenFile)) { continue }
        try {
            $token = (Get-Content $TokenFile -Raw).Trim()
            Invoke-WebRequest -Uri "http://127.0.0.1:8080/api/health" `
                -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing | Out-Null
            $status = "paired"; break
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 503) {
                $status = "unpaired"; break
            }
        }
    }
}

# --- summary -----------------------------------------------------------------
Write-Host ""
Log "Install directory : $Dir"
Log "Bridge binary     : $BridgeBin"
Log "Bridge log        : $LogPath"
Log "Message store     : $Store (user-only ACL - never share or commit)"
Log "Webhook forwarding: $Webhook"
switch ($status) {
    "paired"   { Log "WhatsApp session  : PAIRED and connected - you're done." }
    "unpaired" {
        Log "WhatsApp session  : NOT PAIRED yet."
        Log "Next: stop the task (Stop-ScheduledTask '$TaskName'), run the bridge in a"
        Log "terminal ($BridgeBin), scan the QR it prints"
        Log "(WhatsApp > Settings > Linked Devices), then Start-ScheduledTask '$TaskName'."
    }
    default    { Warn "Bridge did not come up within 20s - check $LogPath." }
}
if ($Dir -ne (Join-Path $env:USERPROFILE ".whatsapp-mcp")) {
    Log "Non-default directory: set WHATSAPP_MCP_DIR=$Dir (user env var) so the MCP launcher finds it."
}
