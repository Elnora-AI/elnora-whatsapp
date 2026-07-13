# elnora-whatsapp setup for Windows — clone, build, harden, and keep the
# WhatsApp bridge running automatically via Task Scheduler.
# macOS/Linux: use scripts/setup.sh instead.
#
# Usage: .\setup.ps1 [-Dir <path>] [-Webhook <url>] [-Port <n>] [-NoService] [-Update] [-Ref <ref>]
[CmdletBinding()]
param(
    [string]$Dir = $(if ($env:WHATSAPP_MCP_DIR) { $env:WHATSAPP_MCP_DIR } else { Join-Path $env:USERPROFILE ".whatsapp-mcp" }),
    [string]$Webhook = "http://127.0.0.1:9/disabled",
    [int]$Port = 8080,
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

# --- input validation --------------------------------------------------------
if ($Webhook -match '[|<>"''\s]') { Die "-Webhook URL contains unsupported characters." }
# Canonicalize so rendered files always hold an absolute path (PS 5.1-safe).
if (-not [System.IO.Path]::IsPathRooted($Dir)) { $Dir = Join-Path (Get-Location).Path $Dir }
$Dir = [System.IO.Path]::GetFullPath($Dir)

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
        # Fetch from the pinned repo URL, not 'origin' - adopted checkouts may
        # point at a different remote (e.g. the original lharries fork).
        git -C $Dir fetch --quiet $UpstreamRepo $PinnedRef
        git -C $Dir checkout --quiet FETCH_HEAD
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
# The bridge logs full message content to bridge.log; restrict the whole
# install dir (and thus the log) to the current user. Best-effort NTFS ACL.
$Store = Join-Path $BridgeDir "store"
New-Item -ItemType Directory -Force -Path $Store | Out-Null
if (-not (Test-Path $LogPath)) { New-Item -ItemType File -Path $LogPath | Out-Null }
try {
    icacls $Dir /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn "icacls returned $LASTEXITCODE - tighten ACLs on $Dir manually if the machine is shared." }
} catch {
    Warn "Could not tighten ACLs on $Dir - do this manually if the machine is shared."
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
        -replace '\{\{BRIDGE_PORT\}\}', "$Port" `
        -replace '\{\{LOG_PATH\}\}', $LogPath |
        Set-Content -Path $StartCmd -Encoding ASCII

    # Hidden launcher: running the .cmd directly would pin a visible console
    # window to every logon (and closing it would kill the bridge).
    $StartVbs = Join-Path $Dir "bridge-start.vbs"
    "CreateObject(""WScript.Shell"").Run """"""$StartCmd"""""", 0, False" |
        Set-Content -Path $StartVbs -Encoding ASCII

    Log "Registering scheduled task '$TaskName' (runs hidden at logon, restarts on failure)"
    $action   = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "//B `"$StartVbs`""
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet `
        -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
    Start-ScheduledTask -TaskName $TaskName
} else {
    Warn "Skipping keep-alive task (-NoService). Run the bridge manually:"
    Warn "  cd $BridgeDir; `$env:WEBHOOK_URL='$Webhook'; `$env:FORWARD_SELF='$ForwardSelf'; `$env:WHATSAPP_BRIDGE_PORT='$Port'; .\whatsapp-bridge.exe"
}

# --- pairing status ----------------------------------------------------------
# The bridge only opens its REST port once a WhatsApp session exists; on a
# fresh install the QR banner in the log is the "not paired" signal.
$status = "unknown"
if (-not $NoService) {
    Log "Waiting for the bridge to come up..."
    $TokenFile = Join-Path $Store ".bridge-token"
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 2
        if (-not (Test-Path $TokenFile)) { continue }
        try {
            $token = (Get-Content $TokenFile -Raw).Trim()
            Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" `
                -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing | Out-Null
            $status = "paired"; break
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 503) {
                $status = "unpaired"; break
            }
        }
    }
    if ($status -eq "unknown" -and (Test-Path $LogPath) -and
        (Select-String -Path $LogPath -Pattern "Scan this QR code", "Waiting for QR code scan" -Quiet)) {
        $status = "unpaired"
    }
}

# --- summary -----------------------------------------------------------------
Write-Host ""
Log "Install directory : $Dir (user-only ACL)"
Log "Bridge binary     : $BridgeBin"
Log "Bridge log        : $LogPath (contains message content - keep private)"
Log "Message store     : $Store (never share or commit)"
Log "Webhook forwarding: $Webhook"
switch ($status) {
    "paired"   { Log "WhatsApp session  : PAIRED and connected - you're done." }
    "unpaired" {
        Log "WhatsApp session  : NOT PAIRED yet (expected on first install)."
        Log "Next: run scripts\pair.ps1 in a PowerShell window - it shows a QR code;"
        Log "scan it from your phone (WhatsApp > Settings > Linked Devices)."
    }
    default    { Warn "Bridge state unclear after 20s - check $LogPath, then run scripts\doctor.ps1." }
}
if ($Dir -ne (Join-Path $env:USERPROFILE ".whatsapp-mcp")) {
    Log "Non-default directory: set WHATSAPP_MCP_DIR=$Dir (user env var) so the MCP launcher finds it."
}
if ($Port -ne 8080) {
    Log "Non-default port: set WHATSAPP_BRIDGE_PORT=$Port and WHATSAPP_API_URL=http://localhost:$Port/api (user env vars)."
}
