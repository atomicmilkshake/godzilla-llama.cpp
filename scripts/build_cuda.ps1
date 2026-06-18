#!/usr/bin/env pwsh
# Godzilla CUDA build (MSVC + WDK UCRT fix for VS18 vcvars).
param(
    [string]$RepoRoot = "J:\LLM\godzilla-llama.cpp",
    [switch]$Reconfigure,
    [switch]$Clean,
    [string]$Target = "llama-server"
)

$ErrorActionPreference = "Stop"
$Vcvars = "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $Vcvars)) {
    $Vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
}
$SdkVer = "10.0.26100.0"
$SdkRoot = "S:\WADK102"
if (-not (Test-Path "$SdkRoot\Include\$SdkVer\ucrt\corecrt.h")) { $SdkVer = "10.0.22621.0" }

cmd /c "`"$Vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match "^(.*?)=(.*)$") { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
}
$env:INCLUDE = "$env:INCLUDE;$SdkRoot\Include\$SdkVer\ucrt"
$env:LIB     = "$env:LIB;$SdkRoot\Lib\$SdkVer\ucrt\x64"
$env:CCACHE_DISABLE = "1"

Push-Location $RepoRoot
try {
    $buildDir = Join-Path $RepoRoot "build"
    if ($Clean -and (Test-Path $buildDir)) { Remove-Item -Recurse -Force $buildDir }
    if ($Reconfigure -or -not (Test-Path (Join-Path $buildDir "CMakeCache.txt"))) {
        cmake -S . -B build -G Ninja `
            -DGGML_CUDA=ON -DGGML_NATIVE=ON -DGGML_CUDA_FA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON `
            -DGGML_CCACHE=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86
        if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
    }
    $buildArgs = @("--build", "build", "--config", "Release", "-j", "8", "--target", $Target)
    cmake @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
    $bin = Join-Path $buildDir "bin\llama-server.exe"
    if (Test-Path $bin) {
        $i = Get-Item $bin
        $impl = Join-Path (Split-Path $bin) "llama-server-impl.dll"
        if ((Test-Path $impl) -and $i.Length -lt 100000) { $i = Get-Item $impl }
        Write-Host "OK $Target $($i.LastWriteTime) $([math]::Round($i.Length/1MB,1)) MB" -ForegroundColor Green
    }
} finally {
    Pop-Location
}