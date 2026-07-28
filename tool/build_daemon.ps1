# Compiles the daemon to a native executable for bundling with the desktop
# app (and standalone distribution). Run before `flutter build windows`.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$daemonDir = Join-Path $root 'packages\daemon'
$outDir = Join-Path $daemonDir 'build'
New-Item -ItemType Directory -Force $outDir | Out-Null

function Copy-DaemonRuntime {
  param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory
  )
  foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -File) {
    try {
      Copy-Item -LiteralPath $file.FullName -Destination $DestinationDirectory -Force
    } catch [System.IO.IOException] {
      Write-Warning "Skipped locked app runtime file '$($file.Name)': $($_.Exception.Message)"
    }
  }
}

Push-Location $daemonDir
try {
  $finalExe = Join-Path $outDir 'daemon.exe'
  $voiceExe = Join-Path $outDir 'coding-agent-voice.exe'
  dart compile exe bin/daemon.dart -o $finalExe
  dart compile exe bin/local_speech_worker.dart -o $voiceExe

  Push-Location $root
  try {
    $sherpaPackage = dart run tool/package_root.dart sherpa_onnx_windows
  } finally {
    Pop-Location
  }
  if ($LASTEXITCODE -ne 0 -or -not $sherpaPackage) {
    throw 'Failed to resolve sherpa_onnx_windows package root'
  }
  $sherpaNativeDir = Join-Path $sherpaPackage.Trim() 'windows'
  $nativeFiles = @(
    'onnxruntime.dll',
    'onnxruntime_providers_shared.dll',
    'sherpa-onnx-c-api.dll',
    'sherpa-onnx-cxx-api.dll'
  )
  foreach ($nativeFile in $nativeFiles) {
    $source = Join-Path $sherpaNativeDir $nativeFile
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      throw "Missing Sherpa native library: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $outDir $nativeFile) -Force
  }
  $sileroAsset = Join-Path $daemonDir 'lib\src\voice\local\sherpa\assets\silero_vad.onnx'
  Copy-Item -LiteralPath $sileroAsset -Destination (Join-Path $outDir 'silero_vad.onnx') -Force

  Write-Host "daemon.exe -> $outDir"
  Write-Host "coding-agent-voice.exe + Sherpa runtime -> $outDir"

  $appRunnerDebug = Join-Path $root 'packages\app\build\windows\x64\runner\Debug'
  if (Test-Path $appRunnerDebug) {
    Copy-DaemonRuntime -SourceDirectory $outDir -DestinationDirectory $appRunnerDebug
    Write-Host "daemon runtime -> $appRunnerDebug"
  }
  $appRunnerRelease = Join-Path $root 'packages\app\build\windows\x64\runner\Release'
  if (Test-Path $appRunnerRelease) {
    Copy-DaemonRuntime -SourceDirectory $outDir -DestinationDirectory $appRunnerRelease
    Write-Host "daemon runtime -> $appRunnerRelease"
  }
} finally {
  Pop-Location
}
