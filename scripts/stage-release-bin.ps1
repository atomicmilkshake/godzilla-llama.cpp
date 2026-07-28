#!/usr/bin/env pwsh
# Stage a self-contained release-bin next to llama-server (no PATH wild goose chase).
#
# Why this exists:
#   Thin PE + impl DLL trees need OpenSSL, full CUDA (bin\x64 on toolkit 13.2),
#   and companion ggml/llama DLLs beside the exe. Missing any of them → Windows
#   "DLL not found" message boxes (STATUS_DLL_NOT_FOUND = 0xC0000135).
#
# Docs: docs/WINDOWS-BUILD-TOOLCHAIN.md
param(
    [string]$RepoRoot = "",
    [string]$BuildBin = "",
    [string]$Dest = "",
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "godzilla-paths.ps1")

if (-not $RepoRoot) { $RepoRoot = Get-GodzillaRepoRoot }
if (-not $BuildBin) {
    foreach ($c in @(
        (Join-Path $RepoRoot "build-king\bin"),
        (Join-Path $RepoRoot "build\bin"),
        (Join-Path $RepoRoot "build\bin\Release")
    )) {
        if (Test-Path (Join-Path $c "llama-server.exe")) { $BuildBin = $c; break }
    }
}
if (-not $BuildBin -or -not (Test-Path (Join-Path $BuildBin "llama-server.exe"))) {
    throw "No llama-server.exe under build-king/bin or build/bin. Build first (rebuild_king.cmd)."
}
if (-not $Dest) { $Dest = Join-Path $RepoRoot "release-bin" }
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

Write-Host "[stage-release-bin] source=$BuildBin"
Write-Host "[stage-release-bin] dest=$Dest"

# 1) All PE companions from the build tree
Get-ChildItem $BuildBin -File | Where-Object {
    $_.Extension -in ".exe", ".dll"
} | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $Dest $_.Name) -Force
    Write-Host "  build: $($_.Name)"
}

# 2) OpenSSL (linked by llama-server-impl / llama-common)
$opensslRoots = @(
    "C:\Program Files\OpenSSL-Win64\bin",
    "C:\Program Files\OpenSSL-Win64",
    "C:\OpenSSL-Win64\bin"
)
$sslNames = @("libssl-4-x64.dll", "libcrypto-4-x64.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll")
foreach ($name in $sslNames) {
    if (Test-Path (Join-Path $Dest $name)) { continue }
    foreach ($root in $opensslRoots) {
        $src = Join-Path $root $name
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $Dest $name) -Force
            Write-Host "  openssl: $name <- $src"
            break
        }
    }
}

# 3) CUDA runtime — toolkit 13.2 puts many DLLs under bin\x64 (not only bin\)
$cudaPath = Get-LabCudaPath
if (-not $cudaPath) { $cudaPath = $env:CUDA_PATH }
$cudaSearch = @()
if ($cudaPath) {
    $cudaSearch += (Join-Path $cudaPath "bin\x64")
    $cudaSearch += (Join-Path $cudaPath "bin")
}
$cudaSearch += @(
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin\x64",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin"
)
$cudaNames = @(
    "cudart64_13.dll", "cublas64_13.dll", "cublasLt64_13.dll",
    "cudart64_12.dll", "cublas64_12.dll", "cublasLt64_12.dll",
    "nvJitLink_130_0.dll", "nvrtc64_130_0.dll", "nvrtc-builtins64_132.dll"
)
foreach ($name in $cudaNames) {
    if (Test-Path (Join-Path $Dest $name)) { continue }
    foreach ($dir in $cudaSearch) {
        $src = Join-Path $dir $name
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $Dest $name) -Force
            Write-Host "  cuda: $name <- $src"
            break
        }
    }
}

# 4) Static PE import closure (must ship or be in System32)
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py -and -not $SkipVerify) {
    $checker = Join-Path $PSScriptRoot "check-release-bin-deps.py"
    if (Test-Path $checker) {
        Write-Host "[stage-release-bin] verifying PE dependency closure..."
        & $py.Source $checker --dir $Dest --exe llama-server.exe
        if ($LASTEXITCODE -ne 0) {
            throw "release-bin dependency check failed (exit $LASTEXITCODE). Fix missing DLLs above."
        }
    }
}

# 5) Smoke: --version with PATH stripped to System32 only
$smoke = Join-Path $env:TEMP "godzilla-release-smoke.cmd"
@"
@echo off
set PATH=C:\Windows\System32;C:\Windows
cd /d "$Dest"
llama-server.exe --version
exit /b %ERRORLEVEL%
"@ | Set-Content $smoke -Encoding ASCII
$p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $smoke -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    throw "Clean-PATH --version failed (exit $($p.ExitCode) / 0x$($p.ExitCode.ToString('X8'))). Missing DLL still present."
}
Write-Host "[stage-release-bin] OK clean-PATH --version" -ForegroundColor Green
Write-Host "[stage-release-bin] Runtime: cwd MUST be $Dest"
