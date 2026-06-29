#!/usr/bin/env pwsh
# Re-run limit (NIAH) profile on certified Qwopus stacks after core.py prompt-budget fix.
param(
    [string[]]$Only = @("qwopus-9b-coder", "qwopus-4b-coder")
)

$ErrorActionPreference = "Stop"
$env:TURBO_INNERQ = "1"

$SomsRoot = "$env:SOMS_ROOT"
$SomsPy = Join-Path $SomsRoot "venv\Scripts\python.exe"
$WatchScript = "$env:BENCHMARK_WATCH_SCRIPT"
$LogDir = Join-Path $SomsRoot "logs\godzilla_hotrod"
$QueueLog = Join-Path $SomsRoot "logs\godzilla_hotrod_queue.log"
$EvidenceDate = Get-Date -Format "yyyy-MM-dd"

. $WatchScript

function Resolve-ModelOnlyFilter {
    param([string[]]$Only)
    if (-not $Only -or $Only.Count -eq 0) { return @() }
    @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object {
        $_.Trim().Trim('"').Trim("'")
    } | Where-Object { $_ })
}

function Invoke-GodzillaMatrixRow {
    param(
        [string]$PresetId, [string]$Variant, [string]$Profile,
        [string]$RowIntent, [string]$Harness, [int]$HeTimeout, [int]$LaunchTimeout,
        [string]$Evidence, [string]$LogFile
    )
    Reset-MatrixZombies
    $args = @(
        "run_matrix_suite.py", "--roster", (Join-Path $SomsRoot "roster.yaml"), "--execute", "--plain",
        "--only-preset", $PresetId,
        "--only-engine", "godzilla",
        "--only-variant", $Variant,
        "--profile", $Profile,
        "--row-intent", $RowIntent,
        "--launch-timeout", "$LaunchTimeout",
        "--evidence", $Evidence,
        "--log-file", $LogFile
    )
    if ($Profile -match "humaneval") {
        $args += @(
            "--humaneval-harness", $Harness,
            "--humaneval-tasks", (Join-Path $SomsRoot "benchmarks\humaneval_small.jsonl"),
            "--humaneval-timeout", "$HeTimeout",
            "--humaneval-test-timeout", "60",
            "--humaneval-max-tokens", "1536"
        )
    }
    return Invoke-MatrixRowActive -Python $SomsPy -ArgumentList $args -WorkingDirectory $SomsRoot `
        -LogPath $LogFile -EvidencePath $Evidence -PresetId $PresetId -QueueLog $QueueLog `
        -Label $PresetId -EnableLaw2
}

$Models = @(
    @{ Id = "qwopus-9b-coder"; PresetId = "Qwopus3.5-9B-coder-Exp Q4_K_M (Jackrong SWE-coding) (Q4_K_M)"; Variant = "baseline-8k"; Harness = "qwen"; LaunchTimeout = 300; HeTimeout = 240 }
    @{ Id = "qwopus-4b-coder"; PresetId = "Qwopus3.5-4B-coder (Q5_K_M)"; Variant = "baseline-8k"; Harness = "qwen"; LaunchTimeout = 300; HeTimeout = 300 }
)

$onlyIds = Resolve-ModelOnlyFilter -Only $Only
if ($onlyIds.Count -gt 0) {
    $Models = @($Models | Where-Object { $onlyIds -contains $_.Id })
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Reset-MatrixZombies

foreach ($m in $Models) {
    $evidence = Join-Path $SomsRoot ("evidence\prepublish_godzilla_hotrod_{0}_{1}.jsonl" -f $m.Id, $EvidenceDate)
    $niahLog = Join-Path $LogDir ("{0}_{1}_niah_8192_reverify_{2}.log" -f $m.Id, ($m.Variant -replace '/','_'), (Get-Date -Format "HHmmss"))
    Write-Host "NIAH reverify: $($m.PresetId) @ $($m.Variant)" -ForegroundColor Cyan
    $exit = Invoke-GodzillaMatrixRow -PresetId $m.PresetId -Variant $m.Variant -Profile "limit" `
        -RowIntent "diagnostic" -Harness $m.Harness -HeTimeout $m.HeTimeout `
        -LaunchTimeout $m.LaunchTimeout -Evidence $evidence -LogFile $niahLog
    Write-Host "  exit=$exit log=$niahLog" -ForegroundColor $(if ($exit -eq 0) { "Green" } else { "Yellow" })
}