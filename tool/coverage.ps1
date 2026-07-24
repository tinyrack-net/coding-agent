#!/usr/bin/env pwsh
# Runs tests with coverage for every workspace package and enforces a minimum
# coverage threshold from the resulting lcov report.
#
# Uses `dart test --coverage` / `flutter test --coverage` (the SDK-standard
# way to collect coverage) plus package:coverage's format_coverage for the
# pure Dart packages. Tests are run directly (not via very_good_cli) because
# very_good_cli auto-detects "flutter test" vs "dart test" per package, and
# in this pub workspace (where one member — packages/app — depends on
# Flutter) it runs every package's tests through `flutter test`, which does
# not reliably honor per-file `@Timeout(...)` overrides the way `dart test`
# does, causing spurious 30s timeouts on the daemon package's slower
# subprocess-spawning integration tests.
#
# Usage: pwsh tool/coverage.ps1 [-MinCoverage 95]

param(
    [int]$MinCoverage = 95
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Ensure-CoverageActivated {
    $activated = dart pub global list 2>$null
    if (-not ($activated -match 'coverage ')) {
        Write-Host '==> Activating package:coverage (format_coverage)'
        dart pub global activate coverage
        if ($LASTEXITCODE -ne 0) { throw 'Failed to activate package:coverage' }
    }
}

# Packages that need real platform-boundary code excluded from the coverage
# denominator (FFI/ConPTY calls, OS window/tray integration, app bootstrap,
# generated code) because they cannot be meaningfully exercised by unit tests.
$packages = @(
    @{ Name = 'protocol'; Path = 'packages/protocol'; Flutter = $false; Exclude = @() }
    @{ Name = 'daemon_lifecycle'; Path = 'packages/daemon_lifecycle'; Flutter = $false; Exclude = @() }
    @{ Name = 'daemon'; Path = 'packages/daemon'; Flutter = $false; Exclude = @(
        '*/pty/pty_unix.dart'
        '*/pty/pty_windows.dart'
        # Several test files spawn real daemon subprocesses/ports
        # (daemon_lock_test.dart, codex/claude session spawn tests). Running
        # test files concurrently (dart test's default) lets that real I/O
        # starve unrelated real-socket tests (ws_server_test.dart) past
        # their 30s timeout under load. Serialize this package's run.
    ); Concurrency = 1 }
    @{ Name = 'app'; Path = 'packages/app'; Flutter = $true; Exclude = @(
        '*/main.dart'
        '*/core/desktop/desktop_shell.dart'
        '*/core/desktop/tray_controller.dart'
        '*.g.dart'
    ) }
)

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

Ensure-CoverageActivated

$failed = @()

foreach ($pkg in $packages) {
    $pkgPath = Join-Path $root $pkg.Path
    Write-Host "==> $($pkg.Name): running tests with coverage"

    Push-Location $pkgPath
    try {
        Remove-Item -Recurse -Force coverage -ErrorAction SilentlyContinue

        if ($pkg.Flutter) {
            flutter test --coverage
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "$($pkg.Name): tests failed"
                $failed += $pkg.Name
                continue
            }
        }
        else {
            $testArgs = @('test', '--coverage=coverage')
            if ($pkg.Concurrency) {
                $testArgs += "--concurrency=$($pkg.Concurrency)"
            }
            dart @testArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "$($pkg.Name): tests failed"
                $failed += $pkg.Name
                continue
            }
            # This is a pub workspace: .dart_tool/package_config.json lives at
            # the workspace root, not inside each member package directory.
            $packageConfig = Join-Path $root '.dart_tool/package_config.json'
            dart pub global run coverage:format_coverage `
                --lcov --check-ignore --in=coverage --out=coverage/lcov.info `
                "--packages=$packageConfig" --report-on=lib
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "$($pkg.Name): format_coverage failed"
                $failed += $pkg.Name
                continue
            }
        }

        $lcovPath = Join-Path (Get-Location) 'coverage/lcov.info'
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
