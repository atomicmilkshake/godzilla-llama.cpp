#!/usr/bin/env pwsh
# Package WSL build-bitnet-cpu llama-server + shared libs for GitHub release.
param(
    [string]$RepoRoot = "",
    [string]$BuildDir = "build-bitnet-cpu",
    [string]$OutDir = "",
    [string]$Tag = ""
)

. (Join-Path $PSScriptRoot "godzilla-paths.ps1")

$ErrorActionPreference = "Stop"
if (-not $RepoRoot) { $RepoRoot = Get-GodzillaRepoRoot }
$binDir = Join-Path $RepoRoot "$BuildDir/bin"
if (-not (Test-Path (Join-Path $binDir "llama-server"))) {
    throw "WSL BitNet binary not found at $binDir/llama-server. Run: pwsh -File scripts/build_bitnet_cpu.ps1 -UseWsl -Target llama-server"
}

$sha = (git -C $RepoRoot rev-parse --short HEAD 2>$null)
if (-not $Tag) {
    $date = Get-Date -Format "yyyyMMdd"
    $Tag = "kv-god-bitnet-$date"
}
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot "release" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$zipName = "godzilla-bitnet-cpu-wsl-x64-$Tag.zip"
$zipPath = Join-Path $OutDir $zipName
$stage = Join-Path $RepoRoot "release/.stage-bitnet-cpu"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
$stageBin = Join-Path $stage "bin"
New-Item -ItemType Directory -Force -Path $stageBin | Out-Null

$wslRoot = Get-WslRepoPath -WinPath $RepoRoot
$wslBin = "$wslRoot/$BuildDir/bin"
$wslStageBin = "$wslRoot/release/.stage-bitnet-cpu/bin"
$readme = @"
Godzilla BitNet CPU (WSL/Linux x64)
===================================
Built with GGML_BITNET_I2_S=ON (Clang). Requires libomp (libomp5 on Ubuntu/Debian).

Usage (from extracted bin/):
  ./llama-server -m `$MODELS_DIR/bitnet-b1.58-2B-4T/ggml-model-i2_s.gguf -c 4096 -ngl 0 --fit off --host 0.0.0.0 --port 8090

Godzilla commit: $sha
See docs/BITNET.md for smoke test and parity gates.
"@

$packCmd = @"
set -euo pipefail
mkdir -p '$wslStageBin'
cd '$wslBin'
cp -L llama-server lib*.so* '$wslStageBin/' 2>/dev/null || cp llama-server lib*.so* '$wslStageBin/'
ls -la '$wslStageBin/'
"@
$packCmd = $packCmd -replace "`r`n", "`n"
wsl -e bash -lc $packCmd

Set-Content -Path (Join-Path $stage "README.txt") -Value $readme -Encoding UTF8
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -Force
Remove-Item -Recurse -Force $stage
$sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host "Created $zipPath ($sizeMb MiB)"
Write-Host "Upload: gh release upload $Tag `"$zipPath`" --clobber"
