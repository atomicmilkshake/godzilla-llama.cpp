#!/usr/bin/env pwsh
# Godzilla CUDA build (MSVC + WDK UCRT fix for VS18 vcvars).
param(
    [string]$RepoRoot = "J:\LLM\godzilla-llama.cpp",
    [switch]$Reconfigure,
    [switch]$Clean,
    [string]$Target = "llama-server",
    [string]$CudaArch = "86",
    [int]$Jobs = 8,
    [string]$SdkRoot = $(if ($env:WDK_ROOT) { $env:WDK_ROOT } else { "S:\WADK102" })
)

$ErrorActionPreference = "Stop"

function Find-Vcvars64 {
    $candidates = @(
        "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    throw "vcvars64.bat not found. Install Visual Studio 2022/18 with the C++ workload."
}

function Import-Vcvars([string]$Vcvars) {
    cmd /c "`"$Vcvars`" >nul 2>&1 && set" | ForEach-Object {
        if ($_ -match "^(.*?)=(.*)$") { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
    }
    $clExe = (Get-Command cl.exe -ErrorAction SilentlyContinue)
    if (-not $clExe) {
        throw "vcvars64 failed: cl.exe not found in PATH after sourcing $Vcvars"
    }
}

function Add-WdkUcrtPaths([string]$Root) {
    if (-not (Test-Path $Root)) {
        throw "WDK/SDK root not found at '$Root'. Set `$env:WDK_ROOT or install the Windows SDK/WDK."
    }
    foreach ($ver in @("10.0.26100.0", "10.0.22621.0", "10.0.22000.0")) {
        $ucrtInclude = Join-Path $Root "Include\$ver\ucrt"
        $corecrt = Join-Path $ucrtInclude "corecrt.h"
        if (Test-Path $corecrt) {
            $env:INCLUDE = "$env:INCLUDE;$ucrtInclude"
            $env:LIB     = "$env:LIB;$(Join-Path $Root "Lib\$ver\ucrt\x64")"
            return $ver
        }
    }
    throw "UCRT headers not found under '$Root'. Expected Include\<ver>\ucrt\corecrt.h"
}

function Invoke-Cmake([string[]]$CmakeArgs) {
    # CMake writes informational messages to stderr; do not treat them as terminating errors.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & cmake @CmakeArgs 2>&1 | Out-Host
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Find-BuiltArtifact([string]$BuildDir, [string]$Name) {
    $candidates = @(
        (Join-Path $BuildDir "bin\$Name.exe"),
        (Join-Path $BuildDir "bin\Release\$Name.exe"),
        (Join-Path $BuildDir "tests\$Name.exe"),
        (Join-Path $BuildDir "$Name.exe")
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return (Get-Item $path) }
    }
    return $null
}

$Vcvars = Find-Vcvars64
Import-Vcvars $Vcvars
$SdkVer = Add-WdkUcrtPaths -Root $SdkRoot
Write-Host "Using vcvars: $Vcvars"
Write-Host "Using WDK UCRT $SdkVer from $SdkRoot"

$env:CCACHE_DISABLE = "1"

Push-Location $RepoRoot
try {
    $buildDir = Join-Path $RepoRoot "build"
    if ($Clean -and (Test-Path $buildDir)) {
        Remove-Item -Recurse -Force $buildDir
        Write-Host "Removed $buildDir"
    }

    $needConfigure = $Reconfigure -or -not (Test-Path (Join-Path $buildDir "CMakeCache.txt"))
    if ($needConfigure) {
        $cfgExit = Invoke-Cmake @(
            "-S", ".", "-B", "build", "-G", "Ninja",
            "-DGGML_CUDA=ON", "-DGGML_NATIVE=ON",
            "-DGGML_CUDA_FA=ON", "-DGGML_CUDA_FA_ALL_QUANTS=ON",
            "-DGGML_CCACHE=OFF", "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_CUDA_ARCHITECTURES=$CudaArch"
        )
        if ($cfgExit -ne 0) { throw "cmake configure failed (exit $cfgExit)" }
    }

    $buildExit = Invoke-Cmake @(
        "--build", "build", "--config", "Release",
        "-j", "$Jobs", "--target", $Target
    )
    if ($buildExit -ne 0) { throw "cmake build failed for target '$Target' (exit $buildExit)" }

    $artifact = Find-BuiltArtifact -BuildDir $buildDir -Name $Target
    if ($artifact) {
        if ($Target -eq "llama-server" -and $artifact.Length -lt 100000) {
            $impl = Join-Path $artifact.DirectoryName "llama-server-impl.dll"
            if (Test-Path $impl) { $artifact = Get-Item $impl }
        }
        Write-Host ("OK {0} -> {1} ({2:N1} MB, {3})" -f `
            $Target, $artifact.FullName, ($artifact.Length / 1MB), $artifact.LastWriteTime) `
            -ForegroundColor Green
    } else {
        Write-Host "OK $Target (build succeeded; no .exe artifact found under $buildDir)" -ForegroundColor Yellow
    }
} finally {
    Pop-Location
}