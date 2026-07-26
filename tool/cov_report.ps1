#!/usr/bin/env pwsh
# Ad-hoc helper: per-file coverage gaps for one package, honoring the same
# exclude globs as coverage.ps1. Prints the aggregate and the worst offenders.
#
# Usage: pwsh tool/cov_report.ps1 app
param(
    [Parameter(Mandatory = $true)][string]$Package,
    [int]$Top = 20
)

$excludes = @{
    'daemon' = @('*/pty/pty_unix.dart', '*/pty/pty_windows.dart')
    'app'    = @('*/main.dart', '*/core/desktop/desktop_shell.dart', '*/core/desktop/tray_controller.dart', '*.g.dart')
}
$excl = if ($excludes.ContainsKey($Package)) { $excludes[$Package] } else { @() }

$root = Split-Path -Parent $PSScriptRoot
$lcov = Join-Path $root "packages/$Package/coverage/lcov.info"
if (-not (Test-Path $lcov)) { throw "no lcov at $lcov" }

$rows = [System.Collections.Generic.List[object]]::new()
$cur = $null; $found = 0; $hit = 0; $totalFound = 0; $totalHit = 0

foreach ($line in Get-Content $lcov) {
    if ($line.StartsWith('SF:')) { $cur = ($line.Substring(3) -replace '\\', '/'); $found = 0; $hit = 0 }
    elseif ($line.StartsWith('LF:')) { $found = [int]$line.Substring(3) }
    elseif ($line.StartsWith('LH:')) { $hit = [int]$line.Substring(3) }
    elseif ($line -eq 'end_of_record' -and $found -gt 0) {
        $skip = $false
        foreach ($p in $excl) { if ($cur -like $p) { $skip = $true } }
        if (-not $skip) {
            $totalFound += $found; $totalHit += $hit
            $rows.Add([pscustomobject]@{
                    Miss = $found - $hit
                    Pct  = [math]::Round(100 * $hit / $found, 1)
                    File = ($cur -replace '.*/lib/', '')
                })
        }
    }
}

$pct = [math]::Round(100 * $totalHit / $totalFound, 2)
$need = [math]::Ceiling(0.95 * $totalFound - $totalHit)
Write-Host "### $Package : $pct%  ($totalHit/$totalFound)  need $need more covered lines for 95%"
$rows | Where-Object { $_.Miss -gt 0 } | Sort-Object -Property Miss -Descending |
    Select-Object -First $Top | Format-Table -AutoSize
