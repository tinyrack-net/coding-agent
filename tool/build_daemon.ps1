# Compiles the daemon to a native executable for bundling with the desktop
# app (and standalone distribution). Run before `flutter build windows`.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$daemonDir = Join-Path $root 'packages\daemon'
$outDir = Join-Path $daemonDir 'build'
New-Item -ItemType Directory -Force $outDir | Out-Null
Push-Location $daemonDir
try {
  $finalExe = Join-Path $outDir 'daemon.exe'
  dart compile exe bin/daemon.dart -o $finalExe
  Write-Host "daemon.exe -> $outDir"

  $appRunnerDebug = Join-Path $root 'packages\app\build\windows\x64\runner\Debug'
  if (Test-Path $appRunnerDebug) {
    Copy-Item $finalExe (Join-Path $appRunnerDebug 'daemon.exe') -Force
    Write-Host "daemon.exe -> $appRunnerDebug"
  }
  $appRunnerRelease = Join-Path $root 'packages\app\build\windows\x64\runner\Release'
  if (Test-Path $appRunnerRelease) {
    Copy-Item $finalExe (Join-Path $appRunnerRelease 'daemon.exe') -Force
    Write-Host "daemon.exe -> $appRunnerRelease"
  }
} finally {
  Pop-Location
}
