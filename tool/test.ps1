#!/usr/bin/env pwsh

param(
    [ValidateSet('smoke', 'feature', 'integration', 'full')]
    [string]$Scope = 'smoke',
    [ValidateSet('all', 'protocol', 'relay', 'daemon_lifecycle', 'daemon', 'app')]
    [string]$Package = 'all',
    [string[]]$TestPath = @(),
    [string]$TestName = '',
    [int]$Concurrency = 0,
    [ValidateRange(1, 20)]
    [int]$Repeat = 1
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logicalCores = [Environment]::ProcessorCount
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$TestPath = @(
    $TestPath |
        ForEach-Object { $_ -split ',' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$packages = [ordered]@{
    protocol = @{
        Path = 'packages/protocol'
        Flutter = $false
        Smoke = @(
            'test/v2_websocket_test.dart'
            'test/workspace_v2_test.dart'
            'test/provider_v2_test.dart'
            'test/terminal_v2_test.dart'
            'test/project_directory_test.dart'
            'test/github_repository_search_test.dart'
        )
    }
    relay = @{
        Path = 'packages/relay'
        Flutter = $false
        Smoke = @(
            'test/relay_crypto_test.dart'
            'test/relay_service_test.dart'
        )
    }
    daemon_lifecycle = @{
        Path = 'packages/daemon_lifecycle'
        Flutter = $false
        Smoke = @(
            'test/versions_test.dart'
            'test/daemon_paths_test.dart'
            'test/pid_lock_test.dart'
        )
    }
    daemon = @{
        Path = 'packages/daemon'
        Flutter = $false
        Smoke = @(
            'test/agent_config_service_test.dart'
            'test/provider_visibility_test.dart'
            'test/timeline_projection_test.dart'
            'test/directory_suggestions_test.dart'
            'test/workspace/project_directory_service_test.dart'
            'test/workspace/github_repository_search_service_test.dart'
        )
    }
    app = @{
        Path = 'packages/app'
        Flutter = $true
        Smoke = @(
            'test/agent_list_test.dart'
            'test/agent_history_provider_test.dart'
            'test/sessions_screen_test.dart'
            'test/add_project_flow_model_test.dart'
            'test/add_project_flow_host_test.dart'
            'test/shorten_path_test.dart'
            'test/provider_model_selection_test.dart'
            'test/workspace_draft_submission_test.dart'
            'test/draft_agent_selection_test.dart'
            'test/create_agent_preferences_test.dart'
            'test/combined_model_selector_test.dart'
        )
    }
}

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

function Invoke-TestSelection {
    param(
        [string]$Name,
        [hashtable]$Definition,
        [string[]]$Paths
    )
    $jobs = Get-StableConcurrency -Name $Name
    $packagePath = Join-Path $root $Definition.Path
    Write-Host "==> $Name [$Scope], concurrency=$jobs"
    Push-Location $packagePath
    try {
        for ($attempt = 1; $attempt -le $Repeat; $attempt++) {
            $attemptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            if ($Repeat -gt 1) {
                Write-Host "    stability run $attempt/$Repeat"
            }
            if ($Definition.Flutter) {
                $args = @('test', '-j', "$jobs", '-r', 'compact')
                if (-not [string]::IsNullOrWhiteSpace($TestName)) {
                    $args += "--name=$TestName"
                }
                $args += $Paths
                flutter @args
            }
            else {
                $args = @('test', "--concurrency=$jobs", '-r', 'compact')
                if (-not [string]::IsNullOrWhiteSpace($TestName)) {
                    $args += "--name=$TestName"
                }
                $args += $Paths
                dart @args
            }
            if ($LASTEXITCODE -ne 0) {
                throw "$Name $Scope tests failed on run $attempt/$Repeat"
            }
            $attemptStopwatch.Stop()
            Write-Host ("    passed in {0:N1}s" -f $attemptStopwatch.Elapsed.TotalSeconds)
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-FullGate {
    $coverageScript = Join-Path $PSScriptRoot 'coverage.ps1'
    $selected = if ($Package -eq 'all') { @($packages.Keys) } else { @($Package) }
    $runRoot = Join-Path $root ".dart_tool/test-runs/$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $pwsh = (Get-Command pwsh).Source
    $processes = @()
    try {
        foreach ($name in $selected) {
            $stdout = Join-Path $runRoot "$name.stdout.log"
            $stderr = Join-Path $runRoot "$name.stderr.log"
            $arguments = @(
                '-NoProfile'
                '-File'
                $coverageScript
                '-Package'
                $name
                '-Concurrency'
                "$(Get-StableConcurrency -Name $name)"
            )
            $start = @{
                FilePath = $pwsh
                ArgumentList = $arguments
                RedirectStandardOutput = $stdout
                RedirectStandardError = $stderr
                PassThru = $true
            }
            if ($IsWindows) { $start.WindowStyle = 'Hidden' }
            $process = Start-Process @start
            $processes += @{
                Name = $name
                Process = $process
                Stdout = $stdout
                Stderr = $stderr
            }
        }

        $failed = @()
        foreach ($entry in $processes) {
            $entry.Process.WaitForExit()
            Write-Host "==> $($entry.Name) coverage output"
            if (Test-Path -LiteralPath $entry.Stdout) {
                Get-Content -LiteralPath $entry.Stdout
            }
            if (Test-Path -LiteralPath $entry.Stderr) {
                foreach ($line in Get-Content -LiteralPath $entry.Stderr) {
                    [Console]::Error.WriteLine($line)
                }
            }
            if ($entry.Process.ExitCode -ne 0) {
                $failed += $entry.Name
            }
        }
        if ($failed.Count -gt 0) {
            throw "Full coverage gate failed for: $($failed -join ', ')"
        }
    }
    finally {
        if (Test-Path -LiteralPath $runRoot) {
            Remove-Item -LiteralPath $runRoot -Recurse -Force
        }
    }
}

function Invoke-ParallelPackageScope {
    param([string]$ParallelScope)
    $selected = @($packages.Keys)
    $runRoot = Join-Path $root ".dart_tool/test-runs/$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $pwsh = (Get-Command pwsh).Source
    $processes = @()
    try {
        foreach ($name in $selected) {
            $stdout = Join-Path $runRoot "$name.stdout.log"
            $stderr = Join-Path $runRoot "$name.stderr.log"
            $arguments = @(
                '-NoProfile'
                '-File'
                $PSCommandPath
                '-Scope'
                $ParallelScope
                '-Package'
                $name
                '-Concurrency'
                "$(Get-StableConcurrency -Name $name)"
                '-Repeat'
                "$Repeat"
            )
            $start = @{
                FilePath = $pwsh
                ArgumentList = $arguments
                RedirectStandardOutput = $stdout
                RedirectStandardError = $stderr
                PassThru = $true
            }
            if ($IsWindows) { $start.WindowStyle = 'Hidden' }
            $processes += @{
                Name = $name
                Process = Start-Process @start
                Stdout = $stdout
                Stderr = $stderr
            }
        }

        $failed = @()
        foreach ($entry in $processes) {
            $entry.Process.WaitForExit()
            Write-Host "==> $($entry.Name) $ParallelScope output"
            if (Test-Path -LiteralPath $entry.Stdout) {
                Get-Content -LiteralPath $entry.Stdout
            }
            if (Test-Path -LiteralPath $entry.Stderr) {
                foreach ($line in Get-Content -LiteralPath $entry.Stderr) {
                    [Console]::Error.WriteLine($line)
                }
            }
            if ($entry.Process.ExitCode -ne 0) {
                $failed += $entry.Name
            }
        }
        if ($failed.Count -gt 0) {
            throw "$ParallelScope tests failed for: $($failed -join ', ')"
        }
    }
    finally {
        if (Test-Path -LiteralPath $runRoot) {
            Remove-Item -LiteralPath $runRoot -Recurse -Force
        }
    }
}

if ($Scope -eq 'full') {
    Invoke-FullGate
    $totalStopwatch.Stop()
    Write-Host ("Full coverage gate passed in {0:N1}s." -f $totalStopwatch.Elapsed.TotalSeconds)
    exit 0
}

if ($Scope -eq 'feature' -and $TestPath.Count -eq 0) {
    throw '-Scope feature requires one or more -TestPath values.'
}
if ($Scope -eq 'feature' -and $Package -eq 'all') {
    throw '-Scope feature requires one explicit -Package.'
}

if ($Package -eq 'all' -and $Scope -in @('smoke', 'integration')) {
    Invoke-ParallelPackageScope -ParallelScope $Scope
    $totalStopwatch.Stop()
    Write-Host ("All $Scope tests passed in {0:N1}s." -f $totalStopwatch.Elapsed.TotalSeconds)
    exit 0
}

$selectedPackages = if ($Package -eq 'all') { @($packages.Keys) } else { @($Package) }
foreach ($name in $selectedPackages) {
    $definition = $packages[$name]
    $paths = switch ($Scope) {
        'smoke' { [string[]]$definition.Smoke }
        'feature' { [string[]]$TestPath }
        'integration' { @() }
    }
    Invoke-TestSelection -Name $name -Definition $definition -Paths $paths
}

$totalStopwatch.Stop()
Write-Host ("All $Scope tests passed in {0:N1}s." -f $totalStopwatch.Elapsed.TotalSeconds)
