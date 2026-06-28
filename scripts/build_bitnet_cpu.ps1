#!/usr/bin/env pwsh
# CPU-only godzilla build with Microsoft BitNet I2_S kernels (Clang required).
param(
    [string]$RepoRoot = "J:\LLM\godzilla-llama.cpp",
    [string]$BuildDir = "build-bitnet-cpu",
    [string]$Target = "llama-cli",
    [switch]$Reconfigure,
    [switch]$UseWsl
)

$ErrorActionPreference = "Stop"

function Invoke-WslBitnetBuild {
    $wslRoot = ($RepoRoot -replace '\\', '/') -replace '^J:', '/mnt/j'
    $wslBuild = "$wslRoot/$BuildDir"
    $reconf = if ($Reconfigure) { "True" } else { "False" }
    $cmd = @"
set -euo pipefail
cd '$wslRoot'
if ! dpkg -s libomp-dev >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y -qq libomp-dev clang cmake build-essential || true
fi
if [ '$reconf' = 'True' ] || [ ! -d '$wslBuild' ]; then
  rm -rf '$wslBuild'
  cmake -S . -B '$wslBuild' \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DGGML_CUDA=OFF \
    -DGGML_BITNET_I2_S=ON \
    -DGGML_BITNET_X86_TL2=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DGGML_OPENMP=ON
fi
cmake --build '$wslBuild' --target '$Target' -j`$(nproc)
ls -la '$wslBuild/bin/$Target' 2>/dev/null || ls -la '$wslBuild/bin/Release/$Target' 2>/dev/null || true
"@
    $cmd = $cmd -replace "`r`n", "`n"
    wsl -e bash -lc $cmd
}

if ($UseWsl -or -not (Get-Command clang -ErrorAction SilentlyContinue)) {
    Write-Host "Building via WSL (Clang) ..."
    Invoke-WslBitnetBuild
    exit $LASTEXITCODE
}

$vsDev = "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Launch-VsDevShell.ps1"
if (-not (Test-Path $vsDev)) { throw "VS Dev Shell not found; use -UseWsl" }

Push-Location $RepoRoot
try {
    & $vsDev -Arch amd64 -SkipAutomaticLocation | Out-Null
    $nativeBuild = Join-Path $RepoRoot $BuildDir
    if ($Reconfigure -or -not (Test-Path $nativeBuild)) {
        if (Test-Path $nativeBuild) { Remove-Item -Recurse -Force $nativeBuild }
        cmake -S . -B $BuildDir `
            -DCMAKE_BUILD_TYPE=Release `
            -T ClangCL `
            -DCMAKE_C_COMPILER=clang `
            -DCMAKE_CXX_COMPILER=clang++ `
            -DGGML_CUDA=OFF `
            -DGGML_BITNET_I2_S=ON `
            -DGGML_BITNET_X86_TL2=OFF `
            -DLLAMA_BUILD_SERVER=ON
    }
    cmake --build $BuildDir --config Release --target $Target -j 8
} finally {
    Pop-Location
}
