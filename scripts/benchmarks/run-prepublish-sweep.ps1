#!/usr/bin/env pwsh
# Godzilla pre-publish model sweep: KV matrix gate, then §5 hot-rod cert (HE sweep + speed + NIAH).
# "Hot rod" = the best a model can be on the operator GPU host (example: RTX 3080 10GB).
# Use only viable configurations for each model; do not force incompatible features.
param(
    [string]$RepoRoot = "",
    [int]$CtxSize = 512,
    [switch]$SkipDone,
    [switch]$LaunchSmoke,
    [switch]$HotRod = $true,
    [string[]]$Only = @()
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "godzilla-env.ps1")
if (-not $RepoRoot) { $RepoRoot = $GodzillaRepoRoot }
$ModelsDir = Get-ModelsDir
$TriRoot = Get-TriCalibDir
$GemmaTriDir = Join-Path $TriRoot "gemma4"

function Resolve-ModelOnlyFilter {
    param([string[]]$Only)
    if (-not $Only -or $Only.Count -eq 0) { return @() }
    @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object {
        $_.Trim().Trim('"').Trim("'")
    } | Where-Object { $_ })
}

$Models = @(
    @{
        Id = "qwopus-4b-coder"; Label = "Qwopus3.5-4B-coder Q5_K_M"
        Path = (Join-Path $ModelsDir "Qwopus3.5-4B-coder-Q5_K_M.gguf")
        Tri = "$TriRoot\qwen3.5-4b.triattention"; PresetRef = "Qwopus3.5-4B-coder (Q5_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $true
    },
    @{
        Id = "qwopus-9b-coder"; Label = "Qwopus3.5-9B-coder-Exp Q4_K_M"
        Path = (Join-Path $ModelsDir "Qwopus3.5-9B-coder-Exp-Q4_K_M.gguf")
        Tri = "$TriRoot\qwopus3.5-9b-coder-exp.triattention"
        PresetRef = "Qwopus3.5-9B-coder-Exp Q4_K_M (Jackrong SWE-coding) (Q4_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $true
    },
    @{
        Id = "huihui-opus-9b"; Label = "Huihui Opus abliterated Q8_0"
        Path = (Join-Path $ModelsDir "Huihui-Qwen3.5-9B-Claude-4.6-Opus-abliterated.Q8_0.gguf")
        Tri = "$TriRoot\huihui-qwen35-9b-abliterated.triattention"
        PresetRef = "Huihui-Qwen3.5-9B-Claude-4.6-Opus-abliterated.Q8_0.gguf (Q8_0)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $true
    },
    @{
        Id = "vibethinker-3b"; Label = "VibeThinker-3B Q4_K_M"
        Path = (Join-Path $ModelsDir "VibeThinker-3B.i1-Q4_K_M.gguf")
        Tri = (Join-Path $TriRoot "vibethinker-3b.triattention")
        PresetRef = "VibeThinker-3B (Q4_K_M)"
        # Note: turbo variants cause catastrophic PPL collapse on this model (+850%+ vs f16 baseline on KV matrix 20260620_105529).
        # Hot-rod / sweep for godzilla uses baseline only (turbo not viable for quality gate).
        Variant = "baseline-8k"; HeHarness = "qwen"; Coding = $true; Done = $false
    },
    @{
        Id = "qwythos-9b-mythos"; Label = "Qwythos-9B Claude Mythos 5-1M Q6_K"
        Path = (Join-Path $ModelsDir "Qwythos-9B-Claude-Mythos-5-1M-Q6_K.gguf")
        Tri = "$TriRoot\qwythos-9b-mythos.triattention"
        PresetRef = "Qwythos-9B Claude Mythos 5-1M (Q6_K)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $false
    },
    @{
        Id = "negentropy-opus-9b"; Label = "Negentropy Opus 4.7 9B Q4_K_M"
        Path = (Join-Path $ModelsDir "Negentropy-claude-opus-4.7-9B-Q4_K_M.gguf")
        Tri = "$TriRoot\negentropy-opus-9b.triattention"
        PresetRef = "Negentropy-claude-opus-4.7-9B (Q4_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $true
    },
    @{
        Id = "fablevibes-14b-moe"; Label = "Qwen3.6-14B-A3B FableVibes Q4_K_M"
        Path = (Join-Path $ModelsDir "Qwen3.6-14B-A3B-FableVibes-Q4_K_M.gguf")
        Tri = "$TriRoot\qwen36-14b-fablevibes.triattention"
        PresetRef = "Qwen3.6-14B-A3B-FableVibes (Q4_K_M)"
        # Turbo KV compatibility for this MoE not yet confirmed (sweep run interrupted).
        # Default to baseline-8k per the rule: do not use feature if model shows incompatibility.
        Variant = "baseline-8k"; HeHarness = "qwen"; Coding = $true; Done = $false
        KvExtraArgs = @("-ngl", "60", "-ncmoe", "32")
    },
    @{
        Id = "huihui-gemma-4-12b"; Label = "Huihui-gemma-4-12B abliterated Q4_K_M"
        Path = (Join-Path $ModelsDir "Huihui-gemma-4-12B-it-abliterated.Q4_K_M.gguf")
        Tri = "$GemmaTriDir\huihui-gemma-4-12b.triattention"
        PresetRef = "Huihui-gemma-4-12B-it-abliterated (Q4_K_M)"
        # Turbo status TBD for this native Gemma4 (non-hybrid); defaulting to baseline per principle for now.
        # Review KV results before enabling turbo variants.
        Variant = "baseline-8k"; HeHarness = "gemma_hf"; Coding = $true; Done = $false
    },
    @{
        Id = "gemma4-coding"; Label = "gemma4-coding Q4_K_M"
        Path = (Join-Path $ModelsDir "gemma4-coding-Q4_K_M.gguf")
        Tri = "$GemmaTriDir\gemma4-coding-v2.triattention"
        PresetRef = "Gemma4-12B-Coder Fable5-Composer2.5 (Q4_K_M)"
        # Turbo incompatible: KV matrix showed +9.86% turbo, +31% tcq vs f16 (gate FAIL).
        # Use baseline until hybrid ISWA / turbo issues resolved (see triattention-iswa plan + kv logs).
        Variant = "baseline-8k"; HeHarness = "gemma_hf"; Coding = $true; Done = $false
    },
    @{
        Id = "lfm25-8b"; Label = "LFM2.5-8B-A1B Q4_K_M"
        Path = (Join-Path $ModelsDir "LFM2.5-8B-A1B-Q4_K_M.gguf")
        Tri = "$TriRoot\lfm25-8b-a1b.triattention"
        PresetRef = "LiquidAI LFM2.5-8B-A1B (Q4_K_M)"
        # Turbo KV incompatible (previous matrices showed FAIL on turbo + context create issues on kvarn).
        # Hot-rod on godzilla uses the viable moe_ncpu32 / baseline style.
        Variant = "moe_ncpu32"; HeHarness = "qwen"; Coding = $false; Done = $false
    },
    @{
        Id = "qwen3-coder-30b"; Label = "Qwen3-Coder-30B-A3B IQ1_M"
        Path = (Join-Path $ModelsDir "Qwen3-Coder-30B-A3B-Instruct-UD-IQ1_M.gguf")
        Tri = "$TriRoot\qwen3-coder-30b-a3b.triattention"
        PresetRef = "Qwen3-Coder-30B-A3B-Instruct-UD-IQ1_M.gguf (IQ1_M)"
        # Turbo KV incompatible (+8.57% on turbo3/turbo4, much worse on tcq; gate FAIL).
        # Hot-rod uses the extra-args baseline-style for this MoE.
        Variant = "moe_ncpu32"; HeHarness = "qwen"; Coding = $true; Done = $false
        KvExtraArgs = @("-ngl", "60", "-ncmoe", "32")
    }
)

$onlyIds = Resolve-ModelOnlyFilter -Only $Only
if ($onlyIds.Count -gt 0) {
    $Models = @($Models | Where-Object { $onlyIds -contains $_.Id })
}
if ($SkipDone) {
    $Models = $Models | Where-Object { -not $_.Done }
}

$LogDir = Join-Path $RepoRoot "logs\benchmarks"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$SummaryPath = Join-Path $LogDir "prepublish_sweep_summary.tsv"
$SweepLockPath = Join-Path $LogDir "prepublish_sweep.lock"
$GemmaAutopilotLock = Join-Path $LogDir "gemma4_coding_autopilot.lock"

function Ensure-TsvSchema {
    param([string]$Path)
    Ensure-PrepublishSweepTsvSchema -Path $Path
}

function Upsert-TsvRow {
    param(
        [string]$Path,
        [string]$ModelId,
        [string]$Row
    )
    Upsert-PrepublishSweepTsvRow -Path $Path -ModelId $ModelId -Row $Row
}

function Test-SweepLockHeld {
    if (-not (Test-Path $SweepLockPath)) { return $false }
    $owner = Get-Content $SweepLockPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($owner -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { return $true }
    Remove-Item $SweepLockPath -Force -ErrorAction SilentlyContinue
    return $false
}

function Enter-SweepLock {
    if (Test-FileLockHeld -Path $GemmaAutopilotLock) {
        $gpid = (Get-Content $GemmaAutopilotLock -ErrorAction SilentlyContinue | Select-Object -First 1)
        throw "gemma4 autopilot lock active (PID $gpid); sweep deferred"
    }
    if (Test-SweepLockHeld) {
        throw "prepublish sweep lock held by another process"
    }
    Enter-GodzillaGpuLock -Wait -Operation "prepublish-sweep"
    Set-Content -Path $SweepLockPath -Value $PID -Encoding ASCII
}

function Exit-SweepLock {
    if (Test-Path $SweepLockPath) {
        $owner = Get-Content $SweepLockPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($owner -eq "$PID") { Remove-Item $SweepLockPath -Force -ErrorAction SilentlyContinue }
    }
    Exit-GodzillaGpuLock
}

$EnsureTri = Join-Path $RepoRoot "scripts\ensure-triattention.ps1"
$KvMatrix = Join-Path $RepoRoot "scripts\benchmarks\run-kv-matrix.ps1"
$LaunchSmokeScript = Join-Path $RepoRoot "scripts\benchmarks\run-launch-smoke.ps1"
$HotRodScript = Join-Path $RepoRoot "scripts\benchmarks\run-godzilla-hotrod-cert.ps1"

Ensure-TsvSchema -Path $SummaryPath
Enter-SweepLock
try {

$commit = git -C $RepoRoot rev-parse --short HEAD 2>$null
Write-Host "== Godzilla pre-publish sweep @ $commit ==" -ForegroundColor Cyan
Write-Host "Models: $($Models.Count)" -ForegroundColor Gray
$sweepFailed = $false

foreach ($m in $Models) {
    Write-Host "`n--- $($m.Label) ($($m.Id)) ---" -ForegroundColor Yellow
    if (-not (Test-Path -LiteralPath $m.Path)) {
        Write-Host "  SKIP: missing $($m.Path)" -ForegroundColor Red
        Upsert-TsvRow -Path $SummaryPath -ModelId $m.Id -Row ("{0}`t{1}`t{2}`tMISSING`tSKIP`t`tfile not found" -f $m.Id, $m.Label, $commit)
        continue
    }

    if ($m.Tri -and -not (Test-Path -LiteralPath $m.Tri)) {
        Write-Host "  Ensuring TriAttention: $($m.Tri)" -ForegroundColor DarkCyan
        & pwsh -NoProfile -File $EnsureTri -Gguf $m.Path -Output $m.Tri
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARN: TriAttention ensure failed (continuing KV without tri smoke)" -ForegroundColor Yellow
        }
    }

    $kvLog = Join-Path $LogDir ("prepublish_kv_{0}_{1}.log" -f $m.Id, (Get-Date -Format "yyyyMMdd_HHmmss"))
    Write-Host "  KV matrix..." -ForegroundColor Cyan
    $kvInvoke = @(
        '-NoProfile', '-File', $KvMatrix,
        '-Model', $m.Path,
        '-CtxSize', "$CtxSize",
        '-IncludeKvarn'
    )
    if ($m.Tri) { $kvInvoke += @('-TriStats', $m.Tri) }
    if ($m.KvExtraArgs -and $m.KvExtraArgs.Count -gt 0) {
        $env:GODZILLA_KV_MATRIX_EXTRA = ($m.KvExtraArgs -join ' ')
    } else {
        Remove-Item Env:GODZILLA_KV_MATRIX_EXTRA -ErrorAction SilentlyContinue
    }
    & pwsh @kvInvoke 2>&1 | Tee-Object -FilePath $kvLog
    Remove-Item Env:GODZILLA_KV_MATRIX_EXTRA -ErrorAction SilentlyContinue
    $kvExit = $LASTEXITCODE
    $kvGate = if ($kvExit -eq 0) { "PASS" } else { "FAIL" }
    $artifact = ""
    $notes = ""
    if (Test-Path -LiteralPath $kvLog) {
        $resultLine = Select-String -Path $kvLog -Pattern 'Results:\s+(.+)$' | Select-Object -Last 1
        if ($resultLine) {
            $artifact = Split-Path $resultLine.Matches[0].Groups[1].Value.Trim() -Leaf
        }
    }
    if (-not $artifact) {
        $notes = "kv_exit=$kvExit;kv_incomplete"
    }

    $hotrodGate = "SKIP"
    if (-not $notes) { $notes = "kv_exit=$kvExit" }

    if ($kvGate -eq "PASS" -and $HotRod) {
        Wait-GodzillaGpuFree -OnWait { Write-Host "  Waiting for GPU before hot-rod..." -ForegroundColor DarkYellow }
        Write-Host "  Hot-rod cert (§5: HE sweep + speed + NIAH)..." -ForegroundColor Cyan
        & pwsh -NoProfile -File $HotRodScript -Only $m.Id
        $hotrodExit = $LASTEXITCODE
        $hotrodGate = if ($hotrodExit -eq 0) { "DONE" } else { "FAIL" }
        if ($hotrodExit -ne 0) { $sweepFailed = $true }
        $notes += ";hotrod_exit=$hotrodExit"
    } elseif ($kvGate -eq "FAIL") {
        $sweepFailed = $true
    }

    Upsert-TsvRow -Path $SummaryPath -ModelId $m.Id -Row ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $m.Id, $m.Label, $commit, $kvGate, $hotrodGate, $artifact, $notes)

    if ($LaunchSmoke -and $m.Tri -and (Test-Path -LiteralPath $m.Tri)) {
        if (Test-Path $LaunchSmokeScript) {
            Write-Host "  launch_smoke..." -ForegroundColor Cyan
            & pwsh -NoProfile -File $LaunchSmokeScript -Model $m.Path -TriStats $m.Tri 2>&1 | Out-Null
        }
    }
}

Write-Host "`nSummary: $SummaryPath" -ForegroundColor Green
if ($sweepFailed) { exit 1 }

} finally {
    Exit-SweepLock
}