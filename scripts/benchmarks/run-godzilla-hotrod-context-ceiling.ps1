#!/usr/bin/env pwsh
# Top-down context ceiling sweep on certified godzilla hot rods.
# Start at educated per-model max rung (RAM-KV -nkvo), descend until launch+NIAH+HE-small pass.
param(
    [string[]]$Only = @(),
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

$SomsRoot = "$env:SOMS_ROOT"
$SomsPy = Join-Path $SomsRoot "venv\Scripts\python.exe"
$WatchScript = "$env:BENCHMARK_WATCH_SCRIPT"
$LogDir = Join-Path $SomsRoot "logs\godzilla_hotrod"
$QueueLog = Join-Path $SomsRoot "logs\godzilla_hotrod_context_ceiling_queue.log"
$SummaryPath = "$GodzillaRepoRoot\logs\benchmarks\hotrod_context_ceiling_summary.tsv"
$HumanevalSmall = Join-Path $SomsRoot "benchmarks\humaneval_small.jsonl"
$Script:DescentRungs = @(200000, 131072, 65536, 32768, 16384)

. $WatchScript
New-Item -ItemType Directory -Force -Path $LogDir, (Split-Path $SummaryPath), (Join-Path $SomsRoot "logs"), (Join-Path $SomsRoot "evidence") | Out-Null

$Models = @(
    @{ Id = "qwopus-4b-coder"; PresetId = "Qwopus3.5-4B-coder (Q5_K_M)"; Harness = "qwen"; Stack = "qwen"; StartRung = 200000; HeRef = 29; HeTimeout = 300 },
    @{ Id = "huihui-opus-9b"; PresetId = "Huihui-Qwen3.5-9B-Claude-4.6-Opus-abliterated.Q8_0.gguf (Q8_0)"; Harness = "qwen"; Stack = "qwen"; StartRung = 65536; HeRef = 32; HeTimeout = 300 },
    @{ Id = "negentropy-opus-9b"; PresetId = "Negentropy-claude-opus-4.7-9B (Q4_K_M)"; Harness = "qwen"; Stack = "qwen"; StartRung = 200000; HeRef = 33; HeTimeout = 240 },
    @{ Id = "qwopus-9b-coder"; PresetId = "Qwopus3.5-9B-coder-Exp Q4_K_M (Jackrong SWE-coding) (Q4_K_M)"; Harness = "qwen"; Stack = "qwen"; StartRung = 200000; HeRef = 34; HeTimeout = 240 },
    @{ Id = "qwythos-9b-mythos"; PresetId = "Qwythos-9B Claude Mythos 5-1M (Q6_K)"; Harness = "qwen"; Stack = "qwen"; StartRung = 200000; HeRef = 35; HeTimeout = 300 },
    @{ Id = "gemma4-coding"; PresetId = "Gemma4-12B-Coder Fable5-Composer2.5 (Q4_K_M)"; Harness = "gemma_hf"; Stack = "gemma"; StartRung = 32768; HeRef = 37; HeTimeout = 300 }
)

$onlyIds = Resolve-ModelOnlyFilter -Only $Only
if ($onlyIds.Count -gt 0) {
    $Models = @($Models | Where-Object { $onlyIds -contains $_.Id })
}

function Get-VariantForRung {
    param([hashtable]$Model, [int]$Rung)
    if ($Model.Stack -eq "gemma") {
        switch ($Rung) {
            16384 { return "baseline-16k" }
            32768 { return "ctx-32k-baseline-nkvo" }
            65536 { return "ctx-64k-baseline-nkvo" }
            131072 { return "ctx-128k-baseline-nkvo" }
            default { return $null }
        }
    }
    if ($Rung -eq 16384) { return "turbo3-turbo4-tri" }
    switch ($Rung) {
        32768 { return "ctx-32k-baseline-nkvo" }
        65536 { return "ctx-64k-baseline-nkvo" }
        131072 { return "ctx-128k-baseline-nkvo" }
        200000 { return "ctx-200k-baseline-nkvo" }
        default { return $null }
    }
}

function Get-LaunchTimeoutForRung {
    param([int]$Rung)
    if ($Rung -ge 131072) { return 900 }
    if ($Rung -ge 65536) { return 600 }
    if ($Rung -ge 32768) { return 450 }
    return 300
}

function Test-SystemRamOk {
    param([double]$RequiredGiB = 6.0)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { return $true }
    $freeGiB = [double]$os.FreePhysicalMemory / 1MB
    return ($freeGiB -ge $RequiredGiB)
}

function Get-RungsForModel {
    param([hashtable]$Model)
    $start = $Model.StartRung
    if (-not (Test-SystemRamOk -RequiredGiB 6)) {
        if ($start -gt 65536) { $start = 65536 }
        Write-MatrixQueue -QueueLog $QueueLog -Msg ("RAM low — cap start rung to {0} for {1}" -f $start, $Model.Id)
    }
    @($Script:DescentRungs | Where-Object { $_ -le $start -and $_ -ge 16384 })
}

function Invoke-CeilingMatrixRow {
    param(
        [string]$PresetId, [string]$Variant, [string]$Profile,
        [string]$RowIntent, [string]$Harness, [int]$HeTimeout, [int]$LaunchTimeout,
        [string]$Evidence, [string]$LogFile, [switch]$EnableLaw2
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
            "--humaneval-tasks", $HumanevalSmall,
            "--humaneval-timeout", "$HeTimeout",
            "--humaneval-test-timeout", "60",
            "--humaneval-max-tokens", "1536"
        )
    }
    return Invoke-MatrixRowActive -Python $SomsPy -ArgumentList $args -WorkingDirectory $SomsRoot `
        -LogPath $LogFile -EvidencePath $Evidence -PresetId $PresetId -QueueLog $QueueLog `
        -Label ("{0} @{1}" -f $PresetId, $Variant) -EnableLaw2:$EnableLaw2
}

function Test-NiahPassedAtRung {
    param([string]$EvidencePath, [int]$Rung, [string]$Variant)
    if (-not (Test-Path $EvidencePath)) { return $false }
    foreach ($line in Get-Content $EvidencePath -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if ($row.engine_id -ne "godzilla") { continue }
        if ($row.variant_name -ne $Variant) { continue }
        $prof = if ($row.PSObject.Properties['profile_name']) { [string]$row.profile_name } else { [string]$row.profile }
        if ($prof -ne "limit") { continue }
        $ctx = 0
        $passed = $false
        if ($row.PSObject.Properties['context'] -and $row.context) {
            if ($row.context.PSObject.Properties['attempted_tokens']) { $ctx = [int]$row.context.attempted_tokens }
            elseif ($row.context.PSObject.Properties['proven_tokens']) { $ctx = [int]$row.context.proven_tokens }
            if ($row.context.PSObject.Properties['niah_passed']) { $passed = [bool]$row.context.niah_passed }
            elseif ($row.context.PSObject.Properties['response_contains_needle']) { $passed = [bool]$row.context.response_contains_needle }
        }
        if ($row.PSObject.Properties['context_target']) { $ctx = [int]$row.context_target }
        if ($ctx -eq $Rung -and $passed -and $row.status -ne "fail") { return $true }
    }
    return $false
}

function Get-SpeedTokSFromEvidence {
    param([string]$EvidencePath, [string]$Variant)
    $best = 0.0
    Get-Content $EvidencePath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.Trim()) { return }
        try { $row = $_ | ConvertFrom-Json } catch { return }
        if ($row.engine_id -ne "godzilla") { continue }
        if ($row.variant_name -ne $Variant) { continue }
        $prof = if ($row.PSObject.Properties['profile_name']) { [string]$row.profile_name } else { [string]$row.profile }
        if ($prof -ne "speed") { continue }
        $t = 0.0
        if ($row.PSObject.Properties['speed'] -and $row.speed.tok_s) { $t = [double]$row.speed.tok_s }
        elseif ($row.PSObject.Properties['tok_s']) { $t = [double]$row.tok_s }
        if ($t -gt $best) { $best = $t }
    }
    return $best
}

function Test-LaunchSmokePassed {
    param([string]$EvidencePath, [string]$Variant)
    if (-not (Test-Path $EvidencePath)) { return $false }
    $passed = $false
    foreach ($line in Get-Content $EvidencePath -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if ($row.variant_name -ne $Variant) { continue }
        $prof = if ($row.PSObject.Properties['profile_name']) { [string]$row.profile_name } else { [string]$row.profile }
        if ($prof -ne "launch_smoke") { continue }
        $passed = ($row.status -eq "pass")
    }
    return $passed
}

function Get-HESmallFromEvidence {
    param([string]$EvidencePath, [string]$Variant)
    $best = 0
    Get-Content $EvidencePath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.Trim()) { return }
        try { $row = $_ | ConvertFrom-Json } catch { return }
        if ($row.engine_id -ne "godzilla") { continue }
        if ($row.variant_name -ne $Variant) { continue }
        $prof = if ($row.PSObject.Properties['profile_name']) { [string]$row.profile_name } else { [string]$row.profile }
        if ($prof -notmatch "humaneval") { continue }
        $p = 0
        if ($row.PSObject.Properties['quality'] -and $row.quality.passed) { $p = [int]$row.quality.passed }
        if ($p -gt $best) { $best = $p }
    }
    return $best
}

if ($WhatIf) {
    Write-Host "GODZILLA HOTROD CONTEXT CEILING (dry-run, top-down)" -ForegroundColor Cyan
    foreach ($m in $Models) {
        $rungs = Get-RungsForModel -Model $m
        Write-Host "  $($m.Id): start=$($m.StartRung) rungs=$($rungs -join ',') HE_ref=$($m.HeRef)/40"
    }
    Write-Host "  Summary: $SummaryPath"
    exit 0
}

if (-not (Test-Path $SummaryPath)) {
    "model_id`tpreset_ref`twinner_rung`twinner_variant`tlimit_peak`ttok_s`the_small`the_delta`tfallback`tevidence" | Set-Content $SummaryPath -Encoding UTF8
}

if (Test-FileLockHeld -Path $PrepublishSweepLockPath) {
    Write-Error "prepublish KV sweep active — defer context ceiling until GPU sweep completes"
    exit 1
}
Wait-GodzillaGpuFree -OnWait { Write-Host "Waiting for GPU before context ceiling..." -ForegroundColor DarkYellow }
Enter-GodzillaGpuLock -Operation "hotrod-context-ceiling"

$LockFile = Join-Path $SomsRoot "logs\godzilla_hotrod.context_ceiling.lock"
if (Test-Path $LockFile) {
    $lockPid = 0
    [void][int]::TryParse((Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$lockPid)
    if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
        Write-Error "Context ceiling already running (PID $lockPid)"
        exit 1
    }
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
if (Test-MatrixSuiteBusy) {
    Write-Error "run_matrix_suite.py already active"
    exit 1
}
$PID | Set-Content $LockFile -Encoding ascii

try {
    Write-MatrixQueue -QueueLog $QueueLog -Msg "GODZILLA HOTROD CONTEXT CEILING START ($($Models.Count) models, top-down, RAM-KV)"
    $heMin = 4  # Law 1: 10% of 40 tasks

    foreach ($m in $Models) {
        $evidence = Join-Path $SomsRoot ("evidence\hotrod_context_ceiling_{0}_{1}.jsonl" -f $m.Id, $EvidenceDate)
        $rungs = Get-RungsForModel -Model $m
        $winner = $null
        Write-Host "`n=== Context ceiling (top-down): $($m.Id) ===" -ForegroundColor Cyan
        Write-MatrixQueue -QueueLog $QueueLog -Msg ("CEILING {0} start={1} rungs={2}" -f $m.Id, $m.StartRung, ($rungs -join ','))

        foreach ($rung in $rungs) {
            $variant = Get-VariantForRung -Model $m -Rung $rung
            if (-not $variant) {
                Write-MatrixQueue -QueueLog $QueueLog -Msg ("SKIP {0} rung={1} no variant" -f $m.Id, $rung)
                continue
            }
            $lt = Get-LaunchTimeoutForRung -Rung $rung
            $tag = "{0}_{1}" -f $m.Id, ($variant -replace '[/\\]', '_')
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("PROBE {0} rung={1} variant={2}" -f $m.Id, $rung, $variant)

            $smokeLog = Join-Path $LogDir ("{0}_launch_smoke_{1}.log" -f $tag, (Get-Date -Format "HHmmss"))
            $null = Invoke-CeilingMatrixRow -PresetId $m.PresetId -Variant $variant -Profile "launch_smoke" `
                -RowIntent "launch_smoke" -Harness $m.Harness -HeTimeout $m.HeTimeout `
                -LaunchTimeout $lt -Evidence $evidence -LogFile $smokeLog
            if (-not (Test-LaunchSmokePassed -EvidencePath $evidence -Variant $variant)) {
                Write-MatrixQueue -QueueLog $QueueLog -Msg ("FAIL launch {0} rung={1}" -f $m.Id, $rung)
                continue
            }

            $niahLog = Join-Path $LogDir ("{0}_limit_{1}.log" -f $tag, (Get-Date -Format "HHmmss"))
            $niahExit = Invoke-CeilingMatrixRow -PresetId $m.PresetId -Variant $variant -Profile "limit" `
                -RowIntent "diagnostic" -Harness $m.Harness -HeTimeout $m.HeTimeout `
                -LaunchTimeout $lt -Evidence $evidence -LogFile $niahLog
            if ($niahExit -ne 0 -or -not (Test-NiahPassedAtRung -EvidencePath $evidence -Rung $rung -Variant $variant)) {
                Write-MatrixQueue -QueueLog $QueueLog -Msg ("FAIL niah {0} rung={1}" -f $m.Id, $rung)
                continue
            }

            $speedLog = Join-Path $LogDir ("{0}_speed_{1}.log" -f $tag, (Get-Date -Format "HHmmss"))
            $null = Invoke-CeilingMatrixRow -PresetId $m.PresetId -Variant $variant -Profile "speed" `
                -RowIntent "diagnostic" -Harness $m.Harness -HeTimeout $m.HeTimeout `
                -LaunchTimeout $lt -Evidence $evidence -LogFile $speedLog
            $tokS = Get-SpeedTokSFromEvidence -EvidencePath $evidence -Variant $variant

            $heLog = Join-Path $LogDir ("{0}_he_small_{1}.log" -f $tag, (Get-Date -Format "HHmmss"))
            $heExit = Invoke-CeilingMatrixRow -PresetId $m.PresetId -Variant $variant -Profile "humaneval" `
                -RowIntent "diagnostic" -Harness $m.Harness -HeTimeout $m.HeTimeout `
                -LaunchTimeout $lt -Evidence $evidence -LogFile $heLog -EnableLaw2
            $heScore = Get-HESmallFromEvidence -EvidencePath $evidence -Variant $variant
            $heDelta = $heScore - $m.HeRef
            if ($heExit -ne 0 -or $heScore -lt ($m.HeRef - $heMin)) {
                Write-MatrixQueue -QueueLog $QueueLog -Msg ("FAIL he {0} rung={1} score={2}/40 ref={3} delta={4}" -f $m.Id, $rung, $heScore, $m.HeRef, $heDelta)
                continue
            }

            $winner = @{
                Rung = $rung; Variant = $variant; TokS = $tokS; HEScore = $heScore; HEDelta = $heDelta
            }
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("WIN {0} rung={1} variant={2} tok_s={3} he={4}/40 delta={5}" -f $m.Id, $rung, $variant, $tokS, $heScore, $heDelta)
            break
        }

        if ($winner) {
            $fb = "baseline-8k@8192"
            Add-Content $SummaryPath ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}/40`t{7}`t{8}`t{9}" -f `
                $m.Id, $m.PresetId, $winner.Rung, $winner.Variant, $winner.Rung, $winner.TokS, $winner.HEScore, $winner.HEDelta, $fb, $evidence)
            Write-Host "  WIN: $($winner.Rung) @ $($winner.Variant) | HE $($winner.HEScore)/40 | $($winner.TokS) tok/s" -ForegroundColor Green
        } else {
            Add-Content $SummaryPath ("{0}`t{1}`t8192`tbaseline-8k`t8192`t`t{2}/40`t0`tbaseline-8k cert`t{3}" -f $m.Id, $m.PresetId, $m.HeRef, $evidence)
            Write-MatrixQueue -QueueLog $QueueLog -Msg ("FALLBACK {0} baseline-8k cert (no higher rung passed)" -f $m.Id)
            Write-Host "  FALLBACK: baseline-8k cert stack" -ForegroundColor Yellow
        }
    }

    Write-MatrixQueue -QueueLog $QueueLog -Msg "GODZILLA HOTROD CONTEXT CEILING COMPLETE"
    Write-Host "`nSummary: $SummaryPath" -ForegroundColor Green
} finally {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    Exit-GodzillaGpuLock
}