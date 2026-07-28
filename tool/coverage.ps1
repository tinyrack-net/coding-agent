#!/usr/bin/env pwsh
# Runs tests with coverage for every workspace package and enforces a minimum
# coverage threshold from the resulting lcov report.
#
# Uses `dart test --coverage` / `flutter test --coverage` (the SDK-standard
# way to collect coverage) plus the repository's deterministic VM JSON merger
# for the pure Dart packages. Tests are run directly (not via very_good_cli)
# because
# very_good_cli auto-detects "flutter test" vs "dart test" per package, and
# in this pub workspace (where one member — packages/app — depends on
# Flutter) it runs every package's tests through `flutter test`, which does
# not reliably honor per-file `@Timeout(...)` overrides the way `dart test`
# does, causing spurious 30s timeouts on the daemon package's slower
# subprocess-spawning integration tests.
#
# Usage: pwsh tool/coverage.ps1 [-MinCoverage 95]

param(
    [int]$MinCoverage = 95,
    [ValidateSet('all', 'protocol', 'relay', 'daemon_lifecycle', 'daemon', 'app')]
    [string]$Package = 'all',
    [int]$Concurrency = 0
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logicalCores = [Environment]::ProcessorCount

function Get-StableConcurrency {
    param([string]$Name)
    if ($Concurrency -gt 0) { return $Concurrency }
    $result = switch ($Name) {
        'app' { [Math]::Min(8, [Math]::Max(2, [Math]::Floor($logicalCores / 4))) }
        'daemon' { [Math]::Min(4, [Math]::Max(2, [Math]::Floor($logicalCores / 8))) }
        'daemon_lifecycle' { [Math]::Min(2, [Math]::Max(1, [Math]::Floor($logicalCores / 16))) }
        default { [Math]::Min(4, [Math]::Max(2, [Math]::Floor($logicalCores / 8))) }
    }
    return $result
}

# Packages that need real platform-boundary code excluded from the coverage
# denominator (FFI/ConPTY calls, OS window/tray integration, app bootstrap,
# generated code) because they cannot be meaningfully exercised by unit tests.
$packages = @(
    @{ Name = 'protocol'; Path = 'packages/protocol'; Flutter = $false; Exclude = @() }
    @{ Name = 'relay'; Path = 'packages/relay'; Flutter = $false; Exclude = @() }
    @{ Name = 'daemon_lifecycle'; Path = 'packages/daemon_lifecycle'; Flutter = $false; Exclude = @() }
    @{ Name = 'daemon'; Path = 'packages/daemon'; Flutter = $false; Exclude = @(
        '*/pty/pty_unix.dart'
        '*/pty/pty_windows.dart'
        # Sherpa's production adapter is exercised in its isolated worker
        # process because loading ONNX into the coverage VM is unsafe.
        '*/voice/local/sherpa/native.dart'
        # The process composition root only wires already-tested services and
        # platform/process callbacks. Its assembled HTTP/WS behavior is covered
        # by daemon_v2_workspace_e2e_test.dart and daemon_lock_test.dart.
        '*/daemon_server.dart'
    ) }
    @{ Name = 'app'; Path = 'packages/app'; Flutter = $true; Exclude = @(
        '*/main.dart'
        '*/core/desktop/desktop_shell.dart'
        '*/core/desktop/notification_service.dart'
        '*/core/desktop/tray_controller.dart'
        '*.g.dart'
    ) }
)

if ($Package -ne 'all') {
    $packages = @($packages | Where-Object { $_.Name -eq $Package })
}

function Test-ExcludedFile {
    param([string]$Path, [string[]]$Patterns)
    $normalized = $Path -replace '\\', '/'
    foreach ($pattern in $Patterns) {
        if ($normalized -like $pattern) { return $true }
    }
    return $false
}

# Computes total line coverage % from an lcov file, skipping SF: blocks that
# match any of the given exclude glob patterns.
function Get-LcovCoveragePercent {
    param([string]$LcovPath, [string[]]$ExcludePatterns)

    $totalFound = 0
    $totalHit = 0
    $skip = $false

    foreach ($line in Get-Content -Path $LcovPath) {
        if ($line.StartsWith('SF:')) {
            $file = $line.Substring(3)
            $skip = Test-ExcludedFile -Path $file -Patterns $ExcludePatterns
            continue
        }
        if ($skip) { continue }
        if ($line.StartsWith('LF:')) { $totalFound += [int]$line.Substring(3) }
        elseif ($line.StartsWith('LH:')) { $totalHit += [int]$line.Substring(3) }
    }

    if ($totalFound -eq 0) { return 100.0 }
    return [math]::Round(($totalHit / $totalFound) * 100, 2)
}

$failed = @()

foreach ($pkg in $packages) {
    $pkgPath = Join-Path $root $pkg.Path
    Write-Host "==> $($pkg.Name): running tests with coverage"

    Push-Location $pkgPath
    try {
        Remove-Item -Recurse -Force coverage -ErrorAction SilentlyContinue

        $testConcurrency = Get-StableConcurrency -Name $pkg.Name
        if ($pkg.Flutter) {
            flutter test --coverage --concurrency="$testConcurrency" --reporter=compact
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "$($pkg.Name): tests failed"
                $failed += $pkg.Name
                continue
            }
        }
        else {
            $testArgs = @(
                'test'
                '--coverage=coverage'
                "--concurrency=$testConcurrency"
                '--reporter=compact'
            )
            dart @testArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "$($pkg.Name): tests failed"
                $failed += $pkg.Name
                continue
            }
            dart run "$root/tool/format_vm_coverage.dart" `
                --in=coverage --out=coverage/lcov.info
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "$($pkg.Name): format_coverage failed"
                $failed += $pkg.Name
                continue
            }
        }

        $lcovPath = Join-Path (Get-Location) 'coverage/lcov.info'
        if ((Get-Item -LiteralPath $lcovPath).Length -eq 0) {
            Write-Warning "$($pkg.Name): coverage report is empty"
            $failed += "$($pkg.Name) (empty coverage report)"
            continue
        }

        $percent = Get-LcovCoveragePercent -LcovPath $lcovPath -ExcludePatterns $pkg.Exclude

        if ($percent -lt $MinCoverage) {
            Write-Warning "$($pkg.Name): coverage $percent% is below $MinCoverage%"
            $failed += $pkg.Name
        }
        else {
            Write-Host "$($pkg.Name): coverage $percent% OK"
        }
    }
    finally {
        Pop-Location
    }
}

if ($failed.Count -gt 0) {
    Write-Error "Coverage gate failed for: $($failed -join ', ')"
    exit 1
}

Write-Host "All packages passed the $MinCoverage% coverage gate."
