#!/usr/bin/env pwsh
# Full NIAH (limit profile) + full HumanEval (164 tasks) on certified godzilla hot rods.
# Uses each model's cert stack (baseline-8k) — not humaneval_small.
param(
    [string[]]$Only = @(),
    [switch]$SkipNiah,
    [switch]$SkipHumaneval,
    [switch]$WhatIf,
    [string]$EvidenceDate = (Get-Date -Format "yyyy-MM-dd")
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "godzilla-env.ps1")

function Resolve-ModelOnlyFilter {
    param([string[]]$Only)
    if (-not $Only -or $Only.Count -eq 0) { return @() }
    @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object {
        $_.Trim().Trim('"').Trim("'")
    } | Where-Object { $_ })
}

$SomsRoot = "J:\LLM\soms"
$SomsPy = Join-Path $SomsRoot "venv\Scripts\python.exe"
$WatchScript = "J:\LLM\GuffPuffer\scripts\MatrixRunWatch.ps1"
$LogDir = Join-Path $SomsRoot "logs\godzilla_hotrod"
$QueueLog = Join-Path $SomsRoot "logs\godzilla_hotrod_full_eval_queue.log"
$SummaryPath = "J:\LLM\godzilla-llama.cpp\logs\benchmarks\hotrod_full_eval_summary.tsv"
$HumanevalFull = Join-Path $SomsRoot "benchmarks\humaneval_full.jsonl"

. $WatchScript
New-Item -ItemType Directory -Force -Path $LogDir, (Split-Path $SummaryPath), (Join-Path $SomsRoot "logs"), (Join-Path $SomsRoot "evidence") | Out-Null

# Certified godzilla hot rods @ baseline-8k (canonical roster from prepublish_hotrod_summary.tsv).
$Models = @(
    @{ Id = "qwopus-4b-coder"; PresetId = "Qwopus3.5-4B-coder (Q5_K_M)"; Harness = "qwen"; Variant = "baseline-8k"; HeTimeout = 300; LaunchTimeout = 300 },
    @{ Id = "huihui-opus-9b"; PresetId = "Huihui-Qwen3.5-9B-Claude-4.6-Opus-abliterated.Q8_0.gguf (Q8_0)"; Harness = "qwen"; Variant = "baseline-8k"; HeTimeout = 300; LaunchTimeout = 300 },
    @{ Id = "negentropy-opus-9b"; PresetId = "Negentropy-claude-opus-4.7-9B (Q4_K_M)"; Harness = "qwen"; Variant = "baseline-8k"; HeTimeout = 240; LaunchTimeout = 300 },
    @{ Id = "qwopus-9b-coder"; PresetId = "Qwopus3.5-9B-coder-Exp Q4_K_M (Jackrong SWE-coding) (Q4_K_M)"; Harness = "qwen"; Variant = "baseline-8k"; HeTimeout = 240; LaunchTimeout = 300 },
    @{ Id = "qwythos-9b-mythos"; PresetId = "Qwythos-9B Claude Mythos 5-1M (Q6_K)"; Harness = "qwen"; Variant = "baseline-8k"; HeTimeout = 300; LaunchTimeout = 300 },
    @{ Id = "gemma4-coding"; PresetId = "Gemma4-12B-Coder Fable5-Composer2.5 (Q4_K_M)"; Harness = "gemma_hf"; Variant = "baseline-8k"; HeTimeout = 300; LaunchTimeout = 300 }
)

$onlyIds = Resolve-ModelOnlyFilter -Only $Only
if ($onlyIds.Count -gt 0) {
    $Models = @($Models | Where-Object { $onlyIds -contains $_.Id })
}

if ($WhatIf) {
    Write-Host "GODZILLA HOTROD FULL EVAL (dry-run)" -ForegroundColor Cyan
    Write-Host "  Models: $($Models.Count)"
    foreach ($m in $Models) {
        $phases = @()
        if (-not $SkipNiah) { $phases += "limit (full NIAH)" }
        if (-not $SkipHumaneval) { $phases += "humaneval_full (164 tasks)" }
        Write-Host "  - $($m.Id): $($m.PresetId) @ $($m.Variant) [$($phases -join ', ')]"
    }
    Write-Host "  Summary: $SummaryPath"
    exit 0
}

function Invoke-GodzillaFullEvalRow {
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
            "--humaneval-tasks", $HumanevalFull,
            "--humaneval-timeout", "$HeTimeout",
            "--humaneval-test-timeout", "60",
            "--humaneval-max-tokens", "1536"
        )
    }
    return Invoke-MatrixRowActive -Python $SomsPy -ArgumentList $args -WorkingDirectory $SomsRoot `
        -LogPath $LogFile -EvidencePath $Evidence -PresetId $PresetId -QueueLog $QueueLog `
        -Label $PresetId -EnableLaw2
}

function Get-LimitPeakFromEvidence {
    param([string]$EvidencePath)
    $peak = 0
    Get-Content $EvidencePath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.Trim()) { return }
        try { $row = $_ | ConvertFrom-Json } catch { return }
        if ($row.engine_id -ne "godzilla") { return }
        $prof = if ($row.PSObject.Properties['profile_name']) { [string]$row.profile_name } else { [string]$row.profile }
        if ($prof -ne "limit") { return }
        if ($row.measurement_status -and $row.measurement_status -ne "completed") { return }
        if ($row.status -eq "fail") { return }
        $ctx = 0
        if ($row.PSObject.Properties['context'] -and $row.context.proven_tokens) {
            $ctx = [int]$row.context.proven_tokens
        } elseif ($row.PSObject.Properties['context_target']) {
            $ctx = [int]$row.context_target
        } elseif ($row.PSObject.Properties['context_tokens']) {
            $ctx = [int]$row.context_tokens
        } elseif ($row.PSObject.Properties['highest_pass']) {
            $ctx = [int]$row.highest_pass
        }
        if ($ctx -gt $peak) { $peak = $ctx }
    }
    return $peak
}

function Test-PhaseDoneInEvidence {
    param([string]$EvidencePath, [string]$ProfilePrefix)
    if (-not (Test-Path $EvidencePath)) { return $false }
    foreach ($line in Get-Content $EvidencePath -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if ($row.engine_id -ne "godzilla") { continue }
        $prof = if ($row.PSObject.Properties['profile_name']) { [string]$row.profile_name } else { [string]$row.profile }
        if ($prof -notlike "$ProfilePrefix*") { continue }
        if ($row.measurement_status -eq "completed" -and $row.row_intent -eq "diagnostic") {
            if ($ProfilePrefix -eq "limit") { return $true }
            if ($ProfilePrefix -eq "humaneval" -and $row.PSObject.Properties['quality'] -and $row.quality.total -ge 164) { return $true }
        }
    }
    return $false
}

function Get-HumanevalFullFromEvidence {
    param([string]$EvidencePath)
    $best = 0
    $total = 164
    Get-Content $EvidencePath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.Trim()) { return }
        try { $row = $_ | ConvertFrom-Json } catch { return }
        if ($row.engine_id -ne "godzilla") { return }
        $prof = if ($row.PSObject.Properties['profile_name']) { [string]$row.profile_name } else { [string]$row.profile }
        if ($prof -notmatch "humaneval") { return }
        if ($row.measurement_status -and $row.measurement_status -ne "completed") { return }
        $p = 0
        if ($row.PSObject.Properties['quality'] -and $row.quality.passed) { $p = [int]$row.quality.passed }
        elseif ($row.cum_pass) { $p = [int]$row.cum_pass }
        elseif ($row.passed) { $p = [int]$row.passed }
        if ($p -gt $best) { $best = $p }
        if ($row.PSObject.Properties['quality'] -and $row.quality.total) { $total = [int]$row.quality.total }
    }
    return @{ passed = $best; total = $total }
}

if (-not (Test-Path $SummaryPath)) {
    "model_id`tpreset_ref`tvariant`tlimit_peak_ctx`thumaneval_full`tevidence" | Set-Content $SummaryPath -Encoding UTF8
}

if (Test-FileLockHeld -Path $PrepublishSweepLockPath) {
    Write-Error "prepublish KV sweep active — defer full eval until GPU sweep completes"
    exit 1
}
if (Test-FileLockHeld -Path $HotrodCertLockPath) {
    Write-Error "hot-rod cert active — defer full eval until cert completes"
    exit 1
}
Wait-GodzillaGpuFree -OnWait { Write-Host "Waiting for GPU before hot-rod full eval..." -ForegroundColor DarkYellow }
Enter-GodzillaGpuLock -Operation "hotrod-full-eval"

$LockFile = Join-Path $SomsRoot "logs\godzilla_hotrod.full_eval.lock"
if (Test-Path $LockFile) {
    $lockPid = 0
    [void][int]::TryParse((Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$lockPid)
    if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
        Write-Error "Hot-rod full eval already running (PID $lockPid). Wait or remove stale lock at $LockFile"
        exit 1
    }
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
if (Test-MatrixSuiteBusy) {
    Write-Error "run_matrix_suite.py already active. Kill zombies (Reset-MatrixZombies) before full eval."
    exit 1
}
$PID | Set-Content $LockFile -Encoding ascii

try {
    Write-MatrixQueue -QueueLog $QueueLog -Msg "GODZILLA HOTROD FULL EVAL START ($($Models.Count) models)"
    $anyFail = $false

    foreach ($m in $Models) {
        $evidence = Join-Path $SomsRoot ("evidence\hotrod_full_eval_{0}_{1}.jsonl" -f $m.Id, $EvidenceDate)
        Write-Host "`n=== Full eval: $($m.PresetId) @ $($m.Variant) ===" -ForegroundColor Cyan

        $niahPeak = 0
        $niahExit = 0
        if (-not $SkipNiah -and (Test-PhaseDoneInEvidence -EvidencePath $evidence -ProfilePrefix "limit")) {
            $niahPeak = Get-LimitPeakFromEvidence -EvidencePath $evidence
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("SKIP FULL NIAH {0} already in evidence peak_ctx={1}" -f $m.Id, $niahPeak)
        } elseif (-not $SkipNiah) {
            $niahLog = Join-Path $LogDir ("{0}_{1}_limit_full_{2}.log" -f $m.Id, ($m.Variant -replace '/','_'), (Get-Date -Format "HHmmss"))
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("FULL NIAH {0} variant={1}" -f $m.PresetId, $m.Variant)
            $niahExit = Invoke-GodzillaFullEvalRow -PresetId $m.PresetId -Variant $m.Variant -Profile "limit" `
                -RowIntent "diagnostic" -Harness $m.Harness -HeTimeout $m.HeTimeout `
                -LaunchTimeout $m.LaunchTimeout -Evidence $evidence -LogFile $niahLog
            $niahPeak = Get-LimitPeakFromEvidence -EvidencePath $evidence
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("FULL NIAH done {0} exit={1} peak_ctx={2}" -f $m.Id, $niahExit, $niahPeak)
            if ($niahExit -ne 0) { $anyFail = $true }
        }

        $heScore = "SKIP"
        $heExit = 0
        if (-not $SkipHumaneval -and (Test-PhaseDoneInEvidence -EvidencePath $evidence -ProfilePrefix "humaneval")) {
            $he = Get-HumanevalFullFromEvidence -EvidencePath $evidence
            $heScore = "{0}/{1}" -f $he.passed, $he.total
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("SKIP FULL HE {0} already in evidence score={1}" -f $m.Id, $heScore)
        } elseif (-not $SkipHumaneval) {
            $heLog = Join-Path $LogDir ("{0}_{1}_humaneval_full_{2}.log" -f $m.Id, ($m.Variant -replace '/','_'), (Get-Date -Format "HHmmss"))
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("FULL HE {0} variant={1} tasks=164" -f $m.PresetId, $m.Variant)
            $heExit = Invoke-GodzillaFullEvalRow -PresetId $m.PresetId -Variant $m.Variant -Profile "humaneval_full" `
                -RowIntent "diagnostic" -Harness $m.Harness -HeTimeout $m.HeTimeout `
                -LaunchTimeout $m.LaunchTimeout -Evidence $evidence -LogFile $heLog
            $he = Get-HumanevalFullFromEvidence -EvidencePath $evidence
            $heScore = "{0}/{1}" -f $he.passed, $he.total
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("FULL HE done {0} exit={1} score={2}" -f $m.Id, $heExit, $heScore)
            if ($heExit -ne 0) { $anyFail = $true }
        }

        $limitCol = if ($SkipNiah) { "SKIP" } else { if ($niahPeak -gt 0) { "$niahPeak" } else { "FAIL" } }
        Add-Content $SummaryPath "$($m.Id)`t$($m.PresetId)`t$($m.Variant)`t$limitCol`t$heScore`t$evidence"
        Write-Host "  Limit peak: $limitCol | HumanEval full: $heScore" -ForegroundColor $(if (-not $anyFail) { "Green" } else { "Yellow" })
    }

    Write-Host "`nFull eval summary: $SummaryPath" -ForegroundColor Green
    Write-MatrixQueue -QueueLog $QueueLog -Msg "GODZILLA HOTROD FULL EVAL COMPLETE"
    if ($anyFail) { exit 1 }
} finally {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    Exit-GodzillaGpuLock
}