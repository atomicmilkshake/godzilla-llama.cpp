#!/usr/bin/env pwsh
# Wait for in-flight GPU benchmarks, then KV gate + §5 hot-rod cert for gemma4-coding.
param(
    [string]$RepoRoot = "",
    [string]$ModelPath = "",
    [string]$TriStats = "",
    [int]$PollSeconds = 30
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "godzilla-env.ps1")
$env:TURBO_INNERQ = "1"

if (-not $RepoRoot) { $RepoRoot = $GodzillaRepoRoot }
if (-not $ModelPath) { $ModelPath = Join-Path (Get-ModelsDir) "gemma4-coding-Q4_K_M.gguf" }
if (-not $TriStats) { $TriStats = Join-Path (Get-TriCalibDir) "gemma4/gemma4-coding.triattention" }

$LogDir = Join-Path $RepoRoot "logs\benchmarks"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$QueueLog = Join-Path $LogDir ("queue_gemma4-coding_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Queue([string]$Msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $QueueLog -Value $line
}

$QueuePid = $PID
function Test-BenchmarkBusy {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.ProcessId -eq $QueuePid) { return $false }
            $cmd = $_.CommandLine
            if (-not $cmd) { return $false }
            $cmd -match 'llama-perplexity|llama-server|run-prepublish-sweep|run-kv-matrix|run-godzilla-hotrod|run_matrix_suite'
        }
}

$KvScript = Join-Path $RepoRoot "scripts\benchmarks\run-kv-matrix.ps1"
$HotRodScript = Join-Path $RepoRoot "scripts\benchmarks\run-godzilla-hotrod-cert.ps1"
$EnsureTri = Join-Path $RepoRoot "scripts\ensure-triattention.ps1"

if (-not (Test-Path -LiteralPath $ModelPath)) {
    Write-Queue "ERROR: GGUF missing at $ModelPath"
    exit 1
}

$size = (Get-Item -LiteralPath $ModelPath).Length
Write-Queue "gemma4-coding queue start — GGUF $([math]::Round($size/1GB,2)) GiB @ $ModelPath"

Write-Queue "Waiting for GPU benchmark idle (poll ${PollSeconds}s)..."
while (Test-BenchmarkBusy) {
    Start-Sleep -Seconds $PollSeconds
}
Write-Queue "GPU idle — starting gemma4-coding pipeline"

if (-not (Test-Path -LiteralPath $TriStats)) {
    Write-Queue "TriAttention missing — running ensure-triattention.ps1"
    & pwsh -NoProfile -File $EnsureTri -Gguf $ModelPath -Output $TriStats
    if ($LASTEXITCODE -ne 0) {
        Write-Queue "WARN: tri calibration failed (exit $LASTEXITCODE); continuing KV without tri stats"
    }
}

$kvLog = Join-Path $LogDir ("queue_gemma4_kv_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Write-Queue "KV matrix -> $kvLog"
$kvArgs = @(
    '-NoProfile', '-File', $KvScript,
    '-Model', $ModelPath,
    '-CtxSize', '512',
    '-IncludeKvarn'
)
if (Test-Path -LiteralPath $TriStats) {
    $kvArgs += @('-TriStats', $TriStats)
}
& pwsh @kvArgs 2>&1 | Tee-Object -FilePath $kvLog
$kvExit = $LASTEXITCODE
Write-Queue "KV matrix exit=$kvExit"

Write-Queue "Hot-rod cert (§5) — runs regardless of KV exit"
& pwsh -NoProfile -File $HotRodScript -Only "gemma4-coding" 2>&1 | Tee-Object -FilePath ($kvLog + ".hotrod")
$hotrodExit = $LASTEXITCODE
Write-Queue "Hot-rod cert exit=$hotrodExit"

if ($hotrodExit -ne 0) {
    Write-Queue "FAILED: hot-rod cert exit $hotrodExit"
    exit $hotrodExit
}
Write-Queue "DONE: gemma4-coding hot-rod pipeline complete"
exit 0