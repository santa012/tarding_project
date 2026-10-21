<#
.SYNOPSIS
  Packs the dashboard (code only, no node_modules/build output) and the
  MQL5 EA/script sources into one zip, ready to copy to another machine.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\package_project.ps1
#>

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outDir = Join-Path $root "_package_tmp"
$zipPath = Join-Path $root "GoldTrendEA_Project_$stamp.zip"

if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null

$robocopy = Join-Path $env:SystemRoot "System32\robocopy.exe"

function Invoke-Robocopy {
    param($RSrc, $RDst, $RArgs)
    & $robocopy $RSrc $RDst @RArgs | Out-Null
    # Robocopy uses bit-flag exit codes; 0-7 mean success (some files copied/skipped), 8+ means real failure.
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($RSrc -> $RDst), exit code $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
}

Write-Host "Copying dashboard (excluding node_modules/dist/.git)..."
$dashSrc = Join-Path $root "dashboard"
$dashDst = Join-Path $outDir "dashboard"
Invoke-Robocopy $dashSrc $dashDst @("/E", "/XD", "node_modules", "dist", ".git", "/XF", "*.log")

Write-Host "Copying MQL5 sources..."
$mqlSrc = Join-Path $root "MQL5"
$mqlDst = Join-Path $outDir "MQL5"
Invoke-Robocopy $mqlSrc $mqlDst @("/E", "/XF", "*.ex5")

Write-Host "Copying README..."
$readme = Join-Path $root "README.md"
if (Test-Path $readme) { Copy-Item $readme $outDir -Force }

$setupNotes = @"
# How to deploy this on another machine

1. Unzip this archive anywhere on the new machine.
2. Open PowerShell AS ADMINISTRATOR in the unzipped folder.
3. Run:
     cd dashboard
     powershell -ExecutionPolicy Bypass -File .\setup.ps1
   This installs WSL2 + Docker Desktop if missing, auto-detects the local
   MT5 terminal's log folder, and starts the dashboard at
   http://localhost:8080

   If WSL2 had to be installed fresh, Windows will require a reboot - the
   script tells you this clearly. Reboot, then run the same command again.

4. MQL5 EAs/scripts are under .\MQL5\Experts\GoldTrendEA and .\MQL5\Scripts.
   Copy them into the new machine's MT5 data folder
   (MT5 -> File -> Open Data Folder -> MQL5\Experts / MQL5\Scripts),
   then compile each one in MetaEditor (F7) before using it.
"@
$setupNotes | Out-File (Join-Path $outDir "DEPLOY.md") -Encoding utf8

Write-Host "Zipping..."
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$outDir\*" -DestinationPath $zipPath -CompressionLevel Optimal

Remove-Item $outDir -Recurse -Force

Write-Host ""
Write-Host "Package ready: $zipPath" -ForegroundColor Green
Write-Host "Copy this one file to the other machine, unzip, and follow DEPLOY.md" -ForegroundColor Green
