#!/usr/bin/env pwsh
# Probe godzilla llama-server binary: version, CUDA DLL, capability flags.
param(
    [string]$Binary = "J:\LLM\godzilla-llama.cpp\build\bin\llama-server.exe"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$LogDir = Join-Path $RepoRoot "logs\benchmarks"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Out = Join-Path $LogDir ("preflight_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

if (-not (Test-Path $Binary)) {
    Write-Error "Binary missing: $Binary — build with: cmake --build build -j 8 --target llama-server"
}

$help = & $Binary --help 2>&1 | Out-String
$verLine = ($help -split "`n" | Where-Object { $_ -match "version:" } | Select-Object -First 1)
$bin = Get-Item $Binary
$impl = Join-Path (Split-Path $Binary) "llama-server-impl.dll"
$sizeMb = if ((Test-Path $impl) -and $bin.Length -lt 100000) {
    [math]::Round((Get-Item $impl).Length / 1MB, 2)
} else {
    [math]::Round($bin.Length / 1MB, 2)
}

function Has-Flag([string]$text, [string[]]$needles) {
    $low = $text.ToLower()
    foreach ($n in $needles) { if ($low.Contains($n.ToLower())) { return $true } }
    return $false
}

$cudaDll = Test-Path (Join-Path (Split-Path $Binary) "ggml-cuda.dll")
$report = [ordered]@{
    engine_id     = "godzilla"
    branch        = (git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null)
    commit        = (git -C $RepoRoot rev-parse --short HEAD 2>$null)
    binary_path   = $Binary
    version_line  = $verLine.Trim()
    binary_size_mb = $sizeMb
    binary_mtime_utc = $bin.LastWriteTimeUtc.ToString("o")
    cuda_dll_present = $cudaDll
    capabilities  = [ordered]@{
        turboquant    = Has-Flag $help @("--cache-type-k", "turbo3", "turbo4")
        tcq           = Has-Flag $help @("turbo2_tcq", "turbo3_tcq", "tcq")
        dflash        = Has-Flag $help @("dflash", "--spec-type")
        flash_attn    = Has-Flag $help @("--flash-attn", "-fa")
        triattention  = Has-Flag $help @("--triattention-stats", "triattention-budget")
        ngram_mod     = Has-Flag $help @("ngram", "spec-type")
        reasoning_loop = Has-Flag $help @("reasoning-loop")
    }
    ready         = $true
    probed_at     = (Get-Date).ToUniversalTime().ToString("o")
}

$missing = @()
if (-not $report.capabilities.turboquant) { $missing += "turboquant" }
if (-not $report.capabilities.triattention) { $missing += "triattention" }
if (-not $cudaDll) { $missing += "cuda_dll" }
if ($missing.Count -gt 0) {
    $report.ready = $false
    $report.blockers = $missing
}

$json = $report | ConvertTo-Json -Depth 5
$json | Set-Content $Out -Encoding UTF8
Write-Host $json
Write-Host "`nWrote $Out" -ForegroundColor Gray
if (-not $report.ready) { exit 1 }