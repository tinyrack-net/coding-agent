# Compiles the daemon to a native executable for bundling with the desktop
# app (and standalone distribution). Run before `flutter build windows`.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$daemonDir = Join-Path $root 'packages\daemon'
$outDir = Join-Path $daemonDir 'build'
New-Item -ItemType Directory -Force $outDir | Out-Null
Push-Location $daemonDir
try {
  dart compile exe bin/daemon.dart -o (Join-Path $outDir 'daemon.exe')
  Write-Host "daemon.exe -> $outDir"
} finally {
  Pop-Location
}
