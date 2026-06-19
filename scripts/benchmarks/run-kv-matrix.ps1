#!/usr/bin/env pwsh
# KV quality matrix: PPL across cache-type combos, optional TriAttention overlay.
param(
    [Parameter(Mandatory = $true)]
    [string]$Model,
    [string]$RepoRoot = "J:\LLM\godzilla-llama.cpp",
    [string]$TriStats = "",
    [string]$WikiFile = "",
    [int]$CtxSize = 512,
    [int]$TriBudget = 2048,
    [int]$TriWindow = 128,
    [switch]$IncludeKvarn
)

$ErrorActionPreference = "Stop"

$Perplexity = Join-Path $RepoRoot "build\bin\llama-perplexity.exe"
if (-not (Test-Path $Perplexity)) {
    $Perplexity = Join-Path $RepoRoot "build\bin\Release\llama-perplexity.exe"
}
if (-not (Test-Path $Perplexity)) {
    throw "llama-perplexity not built. Run: cmake --build build -j 8 --target llama-perplexity"
}
if (-not (Test-Path $Model)) { throw "Model not found: $Model" }

$LogDir = Join-Path $RepoRoot "logs\benchmarks"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$ResultsFile = Join-Path $LogDir ("kv_matrix_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

if (-not $WikiFile) {
    $WikiFile = Join-Path $RepoRoot "benchmarks\wikitext\wiki.test.raw.txt"
}
if (-not (Test-Path $WikiFile)) {
    Write-Host "Downloading wikitext-2-raw-v1 test split..." -ForegroundColor Cyan
    $wikiDir = Split-Path $WikiFile -Parent
    New-Item -ItemType Directory -Force -Path $wikiDir | Out-Null
    $py = "J:\LLM\TurboQuantExperimentation\venv-calibrate\Scripts\python.exe"
    if (-not (Test-Path $py)) { $py = (Get-Command python -ErrorAction SilentlyContinue).Source }
    if (-not $py) { throw "Python required to download wikitext" }
    $code = @"
from datasets import load_dataset
from pathlib import Path
out = Path(r"$WikiFile")
    ds = load_dataset("wikitext", "wikitext-2-raw-v1", split="test")
text = "\n".join(ds["text"])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(text, encoding="utf-8")
print(f"wrote {len(text)} chars -> {out}")
"@
    & $py -c $code
}
if (-not (Test-Path $WikiFile)) { throw "wikitext missing: $WikiFile" }

$configs = [System.Collections.Generic.List[hashtable]]::new()
$configs.Add(@{ Label = "f16/f16 baseline"; K = "f16"; V = "f16"; Tri = $false })
$configs.Add(@{ Label = "turbo3/turbo4"; K = "turbo3"; V = "turbo4"; Tri = $false })
$configs.Add(@{ Label = "turbo2_tcq/turbo3_tcq"; K = "turbo2_tcq"; V = "turbo3_tcq"; Tri = $false })
if ($IncludeKvarn) {
    $configs.Add(@{ Label = "kvarn3/kvarn3"; K = "kvarn3"; V = "kvarn3"; Tri = $false })
    $configs.Add(@{ Label = "kvarn4/kvarn4"; K = "kvarn4"; V = "kvarn4"; Tri = $false })
}
# TriAttention is server-only (llama-perplexity has no --triattention-stats); use run-launch-smoke.ps1.

function Invoke-PplRow {
    param($Cfg)
    $args = @(
        "-m", $Model,
        "-ngl", "99",
        "-f", $WikiFile,
        "--ctx-size", "$CtxSize",
        "--batch-size", "$CtxSize",
        "-np", "1",
        "--cache-type-k", $Cfg.K,
        "--cache-type-v", $Cfg.V
    )
    if ($Cfg.K -ne "f16" -or $Cfg.V -ne "f16") {
        $args += @("--flash-attn", "on")
    }
    if ($Cfg.Tri) {
        $args += @(
            "--triattention-stats", $TriStats,
            "--triattention-budget", "$TriBudget",
            "--triattention-window", "$TriWindow"
        )
    }
    Write-Host "`n--- $($Cfg.Label) ---" -ForegroundColor Cyan
    Write-Host "  $($Perplexity) $($args -join ' ')" -ForegroundColor DarkGray
    $output = & $Perplexity @args 2>&1
    $pplLine = ($output | Where-Object { $_ -match "Final estimate|PPL\s*=" } | Select-Object -Last 1)
    if (-not $pplLine) { $pplLine = ($output | Select-Object -Last 3) -join " | " }
    $m = [regex]::Match("$pplLine", "PPL\s*=\s*([\d.]+)")
    $ppl = if ($m.Success) { [double]$m.Groups[1].Value } else { -1.0 }
    Write-Host "  $pplLine" -ForegroundColor $(if ($ppl -gt 0) { "Green" } else { "Red" })
    return [PSCustomObject]@{
        Label = $Cfg.Label
        K = $Cfg.K
        V = $Cfg.V
        Tri = $Cfg.Tri
        PPL = $ppl
        Raw = "$pplLine"
    }
}

$rows = foreach ($c in $configs) { Invoke-PplRow $c }
$baseline = ($rows | Where-Object { $_.K -eq "f16" -and $_.V -eq "f16" -and -not $_.Tri } | Select-Object -First 1).PPL

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("== Godzilla KV Matrix $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==")
$lines.Add("  Repo:   $RepoRoot @ $(git -C $RepoRoot rev-parse --short HEAD 2>$null)")
$lines.Add("  Model:  $Model")
$lines.Add("  Wiki:   $WikiFile")
if ($TriStats) { $lines.Add("  Tri:    $TriStats (budget=$TriBudget window=$TriWindow)") }
$lines.Add("")
foreach ($r in $rows) {
    $lines.Add(("  {0,-34} PPL={1}" -f $r.Label, $(if ($r.PPL -gt 0) { $r.PPL.ToString("F4") } else { "FAIL" })))
}
$lines.Add("")
$lines.Add("  Delta vs f16/f16 (baseline PPL=$baseline):")
$gate = $true
foreach ($r in ($rows | Where-Object { -not ($_.K -eq "f16" -and $_.V -eq "f16" -and -not $_.Tri) })) {
    if ($r.PPL -le 0 -or $baseline -le 0) { $gate = $false; continue }
    $pct = (($r.PPL - $baseline) / $baseline) * 100
    $lines.Add(("    {0,-34} {1:+0.00;-0.00}% ({2:F4})" -f $r.Label, $pct, ($r.PPL - $baseline)))
    if ($pct -gt 2.0 -and -not $r.Tri) {
        Write-Host "  GATE WARN: $($r.Label) >2% PPL drift" -ForegroundColor Yellow
        $gate = $false
    }
}
$lines.Add("")
$lines.Add("  Gate (non-tri configs ≤2% vs f16): $(if ($gate) { 'PASS' } else { 'FAIL' })")
$lines | ForEach-Object { Write-Host $_ }
$lines | Set-Content $ResultsFile -Encoding UTF8
Write-Host "`nResults: $ResultsFile" -ForegroundColor Gray
if (-not $gate) { exit 1 }