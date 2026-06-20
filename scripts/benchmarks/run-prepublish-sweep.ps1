#!/usr/bin/env pwsh
# Godzilla pre-publish model sweep: KV matrix gate, then §5 hot-rod cert (HE sweep + speed + NIAH).
param(
    [string]$RepoRoot = "J:\LLM\godzilla-llama.cpp",
    [int]$CtxSize = 512,
    [switch]$SkipDone,
    [switch]$LaunchSmoke,
    [switch]$HotRod = $true,
    [string[]]$Only = @()
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

$TriRoot = "J:\LLM\TurboQuant-Qwopus-v3-Setup"
$GemmaTriDir = "J:\LLM\Gemma4Models"

$Models = @(
    @{
        Id = "qwopus-4b-coder"; Label = "Qwopus3.5-4B-coder Q5_K_M"
        Path = "J:\MOODLES\Qwopus3.5-4B-coder-Q5_K_M.gguf"
        Tri = "$TriRoot\qwen3.5-4b.triattention"; PresetRef = "Qwopus3.5-4B-coder (Q5_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $true
    },
    @{
        Id = "qwopus-9b-coder"; Label = "Qwopus3.5-9B-coder-Exp Q4_K_M"
        Path = "J:\MOODLES\Qwopus3.5-9B-coder-Exp-Q4_K_M.gguf"
        Tri = "$TriRoot\qwopus3.5-9b-coder-exp.triattention"
        PresetRef = "Qwopus3.5-9B-coder-Exp Q4_K_M (Jackrong SWE-coding) (Q4_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $true
    },
    @{
        Id = "huihui-opus-9b"; Label = "Huihui Opus abliterated Q8_0"
        Path = "J:\MOODLES\Huihui-Qwen3.5-9B-Claude-4.6-Opus-abliterated.Q8_0.gguf"
        Tri = "$TriRoot\huihui-qwen35-9b-abliterated.triattention"
        PresetRef = "Huihui-Qwen3.5-9B-Claude-4.6-Opus-abliterated.Q8_0.gguf (Q8_0)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $true
    },
    @{
        Id = "vibethinker-3b"; Label = "VibeThinker-3B Q4_K_M"
        Path = "J:\MOODLES\VibeThinker-3B.i1-Q4_K_M.gguf"
        Tri = "J:\LLM\VibeThinker\vibethinker-3b.triattention"
        PresetRef = "VibeThinker-3B (Q4_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $false
    },
    @{
        Id = "negentropy-opus-9b"; Label = "Negentropy Opus 4.7 9B Q4_K_M"
        Path = "J:\MOODLES\Negentropy-claude-opus-4.7-9B-Q4_K_M.gguf"
        Tri = "$TriRoot\negentropy-opus-9b.triattention"
        PresetRef = "Negentropy-claude-opus-4.7-9B (Q4_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $true; Done = $false
    },
    @{
        Id = "fablevibes-14b-moe"; Label = "Qwen3.6-14B-A3B FableVibes Q4_K_M"
        Path = "J:\MOODLES\Qwen3.6-14B-A3B-FableVibes-Q4_K_M.gguf"
        Tri = "$TriRoot\qwen36-14b-fablevibes.triattention"
        PresetRef = "Qwen3.6-14B-A3B-FableVibes (Q4_K_M)"
        Variant = "turbo3-turbo4-tri-moe"; HeHarness = "qwen"; Coding = $true; Done = $false
        KvExtraArgs = @("-ngl", "60", "-ncmoe", "32")
    },
    @{
        Id = "huihui-gemma-4-12b"; Label = "Huihui-gemma-4-12B abliterated Q4_K_M"
        Path = "J:\MOODLES\Huihui-gemma-4-12B-it-abliterated.Q4_K_M.gguf"
        Tri = "$GemmaTriDir\huihui-gemma-4-12b.triattention"
        PresetRef = "Huihui-gemma-4-12B-it-abliterated (Q4_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "gemma_hf"; Coding = $true; Done = $false
    },
    @{
        Id = "gemma4-coding"; Label = "gemma4-coding Q4_K_M"
        Path = "J:\MOODLES\gemma4-coding-Q4_K_M.gguf"
        Tri = "$GemmaTriDir\gemma4-coding.triattention"
        PresetRef = "Gemma4-12B-Coder Fable5-Composer2.5 (Q4_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "gemma_hf"; Coding = $true; Done = $false
    },
    @{
        Id = "lfm25-8b"; Label = "LFM2.5-8B-A1B Q4_K_M"
        Path = "J:\MOODLES\LFM2.5-8B-A1B-Q4_K_M.gguf"
        Tri = "$TriRoot\lfm25-8b-a1b.triattention"
        PresetRef = "LiquidAI LFM2.5-8B-A1B (Q4_K_M)"
        Variant = "turbo3-turbo4-tri-8k"; HeHarness = "qwen"; Coding = $false; Done = $false
    },
    @{
        Id = "qwen3-coder-30b"; Label = "Qwen3-Coder-30B-A3B IQ1_M"
        Path = "J:\MOODLES\Qwen3-Coder-30B-A3B-Instruct-UD-IQ1_M.gguf"
        Tri = "$TriRoot\qwen3-coder-30b-a3b.triattention"
        PresetRef = "Qwen3-Coder-30B-A3B-Instruct-UD-IQ1_M.gguf (IQ1_M)"
        Variant = "turbo3-turbo4-tri-moe"; HeHarness = "qwen"; Coding = $true; Done = $false
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
$EnsureTri = Join-Path $RepoRoot "scripts\ensure-triattention.ps1"
$KvMatrix = Join-Path $RepoRoot "scripts\benchmarks\run-kv-matrix.ps1"
$LaunchSmokeScript = Join-Path $RepoRoot "scripts\benchmarks\run-launch-smoke.ps1"
$HotRodScript = Join-Path $RepoRoot "scripts\benchmarks\run-godzilla-hotrod-cert.ps1"

if (-not (Test-Path $SummaryPath)) {
    "model_id`tlabel`tcommit`tkv_gate`thotrod`tartifact`tnotes" | Set-Content $SummaryPath -Encoding UTF8
}

$commit = git -C $RepoRoot rev-parse --short HEAD 2>$null
Write-Host "== Godzilla pre-publish sweep @ $commit ==" -ForegroundColor Cyan
Write-Host "Models: $($Models.Count)" -ForegroundColor Gray
$sweepFailed = $false

foreach ($m in $Models) {
    Write-Host "`n--- $($m.Label) ($($m.Id)) ---" -ForegroundColor Yellow
    if (-not (Test-Path -LiteralPath $m.Path)) {
        Write-Host "  SKIP: missing $($m.Path)" -ForegroundColor Red
        Add-Content $SummaryPath "$($m.Id)`t$($m.Label)`t$commit`tMISSING`t`tfile not found"
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
    if (Test-Path -LiteralPath $kvLog) {
        $resultLine = Select-String -Path $kvLog -Pattern 'Results:\s+(.+)$' | Select-Object -Last 1
        if ($resultLine) {
            $artifact = Split-Path $resultLine.Matches[0].Groups[1].Value.Trim() -Leaf
        }
    }
    if (-not $artifact) {
        $artifact = (Get-ChildItem (Join-Path $LogDir "kv_matrix_*.txt") | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name
    }

    $hotrodGate = "SKIP"
    $notes = "kv_exit=$kvExit"

    if ($kvGate -eq "PASS" -and $HotRod) {
        Write-Host "  Hot-rod cert (§5: HE sweep + speed + NIAH)..." -ForegroundColor Cyan
        & pwsh -NoProfile -File $HotRodScript -Only $m.Id
        $hotrodExit = $LASTEXITCODE
        $hotrodGate = if ($hotrodExit -eq 0) { "DONE" } else { "FAIL" }
        if ($hotrodExit -ne 0) { $sweepFailed = $true }
        $notes += ";hotrod_exit=$hotrodExit"
    } elseif ($kvGate -eq "FAIL") {
        $sweepFailed = $true
    }

    Add-Content $SummaryPath "$($m.Id)`t$($m.Label)`t$commit`t$kvGate`t$hotrodGate`t$artifact`t$notes"

    if ($LaunchSmoke -and $m.Tri -and (Test-Path -LiteralPath $m.Tri)) {
        if (Test-Path $LaunchSmokeScript) {
            Write-Host "  launch_smoke..." -ForegroundColor Cyan
            & pwsh -NoProfile -File $LaunchSmokeScript -Model $m.Path -TriStats $m.Tri 2>&1 | Out-Null
        }
    }
}

Write-Host "`nSummary: $SummaryPath" -ForegroundColor Green
if ($sweepFailed) { exit 1 }