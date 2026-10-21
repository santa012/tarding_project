<#
.SYNOPSIS
  One-command bootstrap for the GoldTrendEA dashboard on a fresh Windows machine.

.DESCRIPTION
  Run this script (as Administrator) from inside the unzipped project folder.
  It will:
    1. Check/install WSL2 (required by Docker Desktop on Windows)
    2. Check/install Docker Desktop (via winget)
    3. Start Docker Desktop and wait for the engine to come up
    4. Auto-detect the local MT5 terminal's MQL5\Files folder and write .env
    5. Build and start the dashboard (docker compose up -d --build)
    6. Open the dashboard in your browser

  IMPORTANT: if WSL2 has to be installed fresh, Windows requires a REBOOT
  before Docker can work. The script will tell you clearly if this happens -
  just reboot and run this same script again; everything already done will
  be skipped automatically.

.EXAMPLE
  Right-click setup.ps1 -> "Run with PowerShell" (as Administrator), or:
  powershell -ExecutionPolicy Bypass -File .\setup.ps1
#>

[CmdletBinding()]
param(
    [string]$Mt5LogsPath
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    WARN: $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 0. Must run elevated (admin) - WSL/Docker install needs it.
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script must run as Administrator. Relaunching elevated..." -ForegroundColor Yellow
    $argList = @("-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Mt5LogsPath) { $argList += @("-Mt5LogsPath", "`"$Mt5LogsPath`"") }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

# ---------------------------------------------------------------------------
# 1. WSL2 - required for Docker Desktop's Linux containers on Windows.
# ---------------------------------------------------------------------------
Write-Step "Checking WSL2..."
$wslStatus = & wsl.exe --status 2>&1
$needsReboot = $false

if ($LASTEXITCODE -ne 0 -or ($wslStatus -join " ") -match "not installed") {
    Write-Warn "WSL2 is not installed. Installing now (this can take a few minutes)..."
    wsl --install --no-distribution
    $needsReboot = $true
} else {
    Write-Ok "WSL2 is already installed."
}

if ($needsReboot) {
    Write-Host "`n*** WSL2 was just installed for the first time. ***" -ForegroundColor Red
    Write-Host "Windows requires a REBOOT before Docker Desktop can use it." -ForegroundColor Red
    Write-Host "Please reboot now, then run this script again (same command)." -ForegroundColor Red
    Write-Host "Everything already done will be skipped automatically on the next run.`n" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Docker Desktop - install via winget if missing.
# ---------------------------------------------------------------------------
Write-Step "Checking Docker Desktop..."
$dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
$dockerExeAlt = "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe"

if (-not (Test-Path $dockerExe) -and -not (Test-Path $dockerExeAlt)) {
    Write-Warn "Docker Desktop not found. Installing via winget..."
    winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    Write-Ok "Docker Desktop installed. It may ask you to log off/on once - follow any on-screen prompts."
} else {
    Write-Ok "Docker Desktop is already installed."
}

$dockerPath = if (Test-Path $dockerExe) { $dockerExe } else { $dockerExeAlt }

# ---------------------------------------------------------------------------
# 3. Start Docker Desktop and wait for the engine.
# ---------------------------------------------------------------------------
Write-Step "Starting Docker Desktop..."
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Start-Process $dockerPath
    Write-Host "    Waiting for Docker engine to come up (this can take 1-3 minutes)..."
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 5
        docker info *> $null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    }
    if (-not $ready) {
        Write-Host "Docker engine did not come up after 5 minutes. Open Docker Desktop manually, wait for it to say 'Running', then re-run this script." -ForegroundColor Red
        exit 1
    }
}
Write-Ok "Docker engine is up."

# ---------------------------------------------------------------------------
# 4. Auto-detect this machine's MT5 terminal Files folder for .env
# ---------------------------------------------------------------------------
Write-Step "Looking for a MetaTrader 5 terminal data folder..."
if (-not $Mt5LogsPath) {
    $terminalRoot = "$env:APPDATA\MetaQuotes\Terminal"
    $candidate = $null
    if (Test-Path $terminalRoot) {
        $candidate = Get-ChildItem $terminalRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "MQL5\Files") } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }
    if ($candidate) {
        $Mt5LogsPath = (Join-Path $candidate.FullName "MQL5\Files") -replace '\\','/'
        Write-Ok "Found: $Mt5LogsPath"
    } else {
        Write-Warn "No MT5 terminal folder found automatically."
        Write-Warn "Open MT5 on this machine at least once (File -> Open Data Folder to confirm the path),"
        Write-Warn "then edit dashboard\.env by hand and set MT5_LOGS_PATH, then re-run this script."
        $Mt5LogsPath = "../MQL5-logs-placeholder"
    }
} else {
    $Mt5LogsPath = $Mt5LogsPath -replace '\\','/'
}

$envFile = Join-Path $PSScriptRoot ".env"
"MT5_LOGS_PATH=$Mt5LogsPath" | Out-File -FilePath $envFile -Encoding utf8 -NoNewline
Write-Ok "Wrote $envFile"

# ---------------------------------------------------------------------------
# 5. Build and start the stack.
# ---------------------------------------------------------------------------
Write-Step "Building and starting the dashboard (docker compose up -d --build)..."
Push-Location $PSScriptRoot
try {
    docker compose up -d --build
} finally {
    Pop-Location
}

Write-Step "Waiting for the API to respond..."
$apiReady = $false
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    try {
        $r = Invoke-RestMethod -Uri "http://localhost:4000/api/health" -TimeoutSec 3
        if ($r.ok) { $apiReady = $true; break }
    } catch {}
}

if ($apiReady) {
    Write-Ok "Dashboard API is healthy."
} else {
    Write-Warn "API did not respond yet - it may still be starting. Check with: docker compose logs server"
}

Write-Step "Opening dashboard..."
Start-Process "http://localhost:8080"

Write-Host "`nAll done. Dashboard: http://localhost:8080" -ForegroundColor Green
Write-Host "If MT5_LOGS_PATH above was a placeholder, edit dashboard\.env and run:" -ForegroundColor Yellow
Write-Host "  docker compose up -d --build" -ForegroundColor Yellow
Write-Host "from this folder once MT5 is installed and you know its real Files path." -ForegroundColor Yellow
