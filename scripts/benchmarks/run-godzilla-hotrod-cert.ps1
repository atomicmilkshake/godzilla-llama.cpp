#!/usr/bin/env pwsh
# Godzilla hot-rod certification (GuffPuffer/SOMS §5) on MEMORY-ALPHA for MOODLES sweep models.
# Phase 2: variant HE sweeps (row_intent=promotion) → Phase 4: speed_frontier on peak → Phase 5: NIAH/limit @ peak KV.
param(
    [string[]]$Only = @(),
    [switch]$SkipNiah,
    [switch]$SkipVariantSweep,
    [switch]$WhatIf,
    [string]$EvidenceDate = (Get-Date -Format "yyyy-MM-dd")
)

$ErrorActionPreference = "Stop"
$env:TURBO_INNERQ = "1"

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
$QueueLog = Join-Path $SomsRoot "logs\godzilla_hotrod_queue.log"
$SummaryPath = "J:\LLM\godzilla-llama.cpp\logs\benchmarks\prepublish_hotrod_summary.tsv"

. $WatchScript
New-Item -ItemType Directory -Force -Path $LogDir, (Split-Path $SummaryPath), (Join-Path $SomsRoot "logs") | Out-Null

$Models = @(
    @{
        Id = "qwopus-4b-coder"
        PresetId = "Qwopus3.5-4B-coder (Q5_K_M)"
        Harness = "qwen"
        Coding = $true
        Variants = @("baseline-8k", "turbo3-turbo4-8k", "turbo3-turbo4-tri-8k", "turbo3-turbo4", "turbo3-turbo4-tri")
        HeTimeout = 300; LaunchTimeout = 300
    },
    @{
        Id = "qwopus-9b-coder"
        PresetId = "Qwopus3.5-9B-coder-Exp Q4_K_M (Jackrong SWE-coding) (Q4_K_M)"
        Harness = "qwen"
        Coding = $true
        Variants = @("baseline-8k", "turbo3-turbo4-8k", "turbo3-turbo4-tri-8k", "turbo3-turbo4", "turbo3-turbo4-tri")
        HeTimeout = 240; LaunchTimeout = 300
    },
    @{
        Id = "huihui-opus-9b"
        PresetId = "Huihui-Qwen3.5-9B-Claude-4.6-Opus-abliterated.Q8_0.gguf (Q8_0)"
        Harness = "qwen"
        Coding = $true
        Variants = @("baseline-8k", "turbo3-turbo4-8k", "turbo3-turbo4-tri-8k", "turbo3-turbo4", "turbo3-turbo4-tri")
        HeTimeout = 300; LaunchTimeout = 300
    },
    @{
        Id = "vibethinker-3b"
        PresetId = "VibeThinker-3B (Q4_K_M)"
        Harness = "qwen"
        Coding = $true
        Variants = @("baseline-8k", "turbo3-turbo4-8k", "turbo3-turbo4-tri-8k")
        HeTimeout = 300; LaunchTimeout = 300
    },
    @{
        Id = "negentropy-opus-9b"
        PresetId = "Negentropy-claude-opus-4.7-9B (Q4_K_M)"
        Harness = "qwen"
        Coding = $true
        Variants = @("baseline-8k", "turbo3-turbo4-8k", "turbo3-turbo4-tri-8k", "turbo3-turbo4", "turbo3-turbo4-tri")
        HeTimeout = 240; LaunchTimeout = 300
    },
    @{
        Id = "fablevibes-14b-moe"
        PresetId = "Qwen3.6-14B-A3B-FableVibes (Q4_K_M)"
        Harness = "qwen"
        Coding = $true
        Variants = @("turbo3-turbo4-moe", "turbo3-turbo4-tri-moe")
        HeTimeout = 240; LaunchTimeout = 300
    },
    @{
        Id = "huihui-gemma-4-12b"
        PresetId = "Huihui-gemma-4-12B-it-abliterated (Q4_K_M)"
        Harness = "gemma_hf"
        Coding = $true
        Variants = @("baseline-8k", "turbo3-turbo4-8k", "turbo3-turbo4-tri-8k", "turbo3-turbo4", "turbo3-turbo4-tri")
        HeTimeout = 300; LaunchTimeout = 300
    },
    @{
        Id = "gemma4-coding"
        PresetId = "Gemma4-12B-Coder Fable5-Composer2.5 (Q4_K_M)"
        Harness = "gemma_hf"
        Coding = $true
        Variants = @("baseline-8k", "turbo3-turbo4-8k", "turbo3-turbo4-tri-8k", "turbo3-turbo4", "turbo3-turbo4-tri")
        HeTimeout = 300; LaunchTimeout = 300
    },
    @{
        Id = "gemma4-31b"
        PresetId = "Gemma 4 31B-it (Q4_K_M)"
        Harness = "gemma_hf"
        Coding = $true
        Variants = @("turbo3-turbo4-8k", "turbo3-turbo4-tri-8k", "turbo3-turbo4", "turbo3-turbo4-tri")
        HeTimeout = 300; LaunchTimeout = 300
    },
    @{
        Id = "lfm25-8b"
        PresetId = "LiquidAI LFM2.5-8B-A1B (Q4_K_M)"
        Harness = "qwen"
        Coding = $true
        Variants = @("moe_ncpu32", "turbo3-turbo4-moe", "turbo3-turbo4-tri-moe")
        HeTimeout = 300; LaunchTimeout = 600
    },
    @{
        Id = "qwen3-coder-30b"
        PresetId = "Qwen3-Coder-30B-A3B-Instruct-UD-IQ1_M.gguf (IQ1_M)"
        Harness = "qwen"
        Coding = $true
        Variants = @("turbo3-turbo4-moe", "turbo3-turbo4-tri-moe")
        HeTimeout = 180; LaunchTimeout = 300
    }
)

$onlyIds = Resolve-ModelOnlyFilter -Only $Only
if ($onlyIds.Count -gt 0) {
    $Models = @($Models | Where-Object { $onlyIds -contains $_.Id })
}

if ($WhatIf) {
    Write-Host "GODZILLA HOTROD CERT (dry-run)" -ForegroundColor Cyan
    Write-Host "  Models: $($Models.Count)"
    foreach ($m in $Models) {
        $phases = @()
        if (-not $SkipVariantSweep -and $m.Coding) {
            $phases += "HE x$($m.Variants.Count)"
        }
        $phases += "speed"
        if (-not $SkipNiah) { $phases += "NIAH/limit" }
        Write-Host "  - $($m.Id): $($m.PresetId) [$($phases -join ', ')]"
    }
    Write-Host "  Summary: $SummaryPath"
    exit 0
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

function Get-PeakFromEvidence {
    param([string]$EvidencePath, [string]$Engine = "godzilla")
    if (-not (Test-Path $EvidencePath)) { return $null }
    $peak = 0
    $best = $null
    Get-Content $EvidencePath -Encoding UTF8 | ForEach-Object {
        if (-not $_.Trim()) { return }
        try { $row = $_ | ConvertFrom-Json } catch { return }
        if ($row.engine_id -ne $Engine) { return }
        if ($row.row_intent -ne "promotion") { return }
        if ($row.measurement_status -ne "completed") { return }
        $p = 0
        if ($row.PSObject.Properties['quality'] -and $row.quality.passed) {
            $p = [int]$row.quality.passed
        } elseif ($row.cum_pass) {
            $p = [int]$row.cum_pass
        } elseif ($row.passed) {
            $p = [int]$row.passed
        }
        if ($p -gt $peak) {
            $peak = $p
            $best = @{ passed = $p; variant = $row.variant_name; engine = $row.engine_id }
        }
    }
    if ($peak -ge 28) { return $best }
    return $null
}

function Test-HotRodCertified {
    param([string]$EvidencePath, [hashtable]$Peak)
    if (-not $Peak) { return $false }
    foreach ($line in Get-Content $EvidencePath -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if ($row.engine_id -ne $Peak.engine) { continue }
        if ($row.variant_name -ne $Peak.variant) { continue }
        $prof = if ($row.PSObject.Properties['profile_name']) { [string]$row.profile_name } else { [string]$row.profile }
        if ($row.row_intent -eq "speed_frontier" -and $prof -eq "speed") { return $true }
    }
    return $false
}

if (-not (Test-Path $SummaryPath)) {
    "model_id`tpreset_ref`tpeak_he`tspeed_frontier`tniah`thotrod_cert`tevidence" | Set-Content $SummaryPath -Encoding UTF8
}

$LockFile = Join-Path $SomsRoot "logs\godzilla_hotrod.cert.lock"
if (Test-Path $LockFile) {
    $lockPid = 0
    [void][int]::TryParse((Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$lockPid)
    if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
        Write-Error "Hot-rod cert already running (PID $lockPid). Use one instance; wait or remove stale lock at $LockFile"
        exit 1
    }
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
if (Test-MatrixSuiteBusy) {
    Write-Error "run_matrix_suite.py already active. Kill zombies (Reset-MatrixZombies) before hot-rod cert."
    exit 1
}
$PID | Set-Content $LockFile -Encoding ascii

try {
Write-MatrixQueue -QueueLog $QueueLog -Msg "GODZILLA HOTROD CERT START ($($Models.Count) models)"
$anyNotCertified = $false

foreach ($m in $Models) {
    $evidence = Join-Path $SomsRoot ("evidence\prepublish_godzilla_hotrod_{0}_{1}.jsonl" -f $m.Id, $EvidenceDate)
    Write-Host "`n=== Hot rod: $($m.PresetId) ===" -ForegroundColor Cyan

    if (-not $SkipVariantSweep -and $m.Coding) {
        foreach ($variant in $m.Variants) {
            $safe = $variant -replace '/', '_'
            $log = Join-Path $LogDir ("{0}_{1}_he_{2}.log" -f $m.Id, $safe, (Get-Date -Format "HHmmss"))
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("PHASE2 HE {0} variant={1}" -f $m.PresetId, $variant)
            $null = Invoke-GodzillaMatrixRow -PresetId $m.PresetId -Variant $variant -Profile "humaneval" `
                -RowIntent "promotion" -Harness $m.Harness -HeTimeout $m.HeTimeout `
                -LaunchTimeout $m.LaunchTimeout -Evidence $evidence -LogFile $log
        }
    }

    $peak = Get-PeakFromEvidence -EvidencePath $evidence
    $peakScore = if ($peak) { $peak.passed } else { 0 }
    $peakVariant = if ($peak) { $peak.variant } else { "" }

    if ($peak) {
        $speedLog = Join-Path $LogDir ("{0}_{1}_speed_{2}.log" -f $m.Id, ($peakVariant -replace '/','_'), (Get-Date -Format "HHmmss"))
        Write-MatrixQueue -QueueLog $QueueLog -Msg ("PHASE4 speed {0} peak={1}/40 stack={2}" -f $m.PresetId, $peakScore, $peakVariant)
        $speedExit = Invoke-GodzillaMatrixRow -PresetId $m.PresetId -Variant $peakVariant -Profile "speed" `
            -RowIntent "speed_frontier" -Harness $m.Harness -HeTimeout $m.HeTimeout `
            -LaunchTimeout $m.LaunchTimeout -Evidence $evidence -LogFile $speedLog
        Write-MatrixQueue -QueueLog $QueueLog -Msg ("PHASE4 speed exit={0} log={1}" -f $speedExit, $speedLog)
    } else {
        Write-MatrixQueue -QueueLog $QueueLog -Msg ("BLOCK {0} no promotion peak >=28/40" -f $m.PresetId)
    }

    $niahGate = "SKIP"
    if (-not $SkipNiah -and $peak) {
        $niahLog = Join-Path $LogDir ("{0}_{1}_niah_{2}.log" -f $m.Id, ($peakVariant -replace '/','_'), (Get-Date -Format "HHmmss"))
        Write-MatrixQueue -QueueLog $QueueLog -Msg ("PHASE5 NIAH {0} @ {1}" -f $m.PresetId, $peakVariant)
        $niahExit = Invoke-GodzillaMatrixRow -PresetId $m.PresetId -Variant $peakVariant -Profile "limit" `
            -RowIntent "diagnostic" -Harness $m.Harness -HeTimeout $m.HeTimeout `
            -LaunchTimeout $m.LaunchTimeout -Evidence $evidence -LogFile $niahLog
        $niahGate = if ($niahExit -eq 0) { "PASS" } else { "FAIL" }
    }

    $cert = Test-HotRodCertified -EvidencePath $evidence -Peak $peak
    $speedGate = if ($cert) { "PASS" } else { "FAIL" }
    $hotrod = if ($cert -and $peakScore -ge 28) { "CERTIFIED" } else { "NOT_CERTIFIED" }

    Add-Content $SummaryPath "$($m.Id)`t$($m.PresetId)`t$peakScore/40`t$speedGate`t$niahGate`t$hotrod`t$evidence"
    Write-Host "  Peak: $peakScore/40 @ $peakVariant | Hot rod: $hotrod" -ForegroundColor $(if ($cert) { "Green" } else { "Yellow" })
    if ($hotrod -ne "CERTIFIED") { $anyNotCertified = $true }
}

Write-Host "`nHot rod summary: $SummaryPath" -ForegroundColor Green
if ($anyNotCertified) { exit 1 }
} finally {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}