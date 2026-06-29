#!/usr/bin/env pwsh
# Build and run TriAttention unit tests (CPU + GPU parity).
. (Join-Path $PSScriptRoot "godzilla-paths.ps1")
$ErrorActionPreference = "Stop"
$RepoRoot = Get-GodzillaRepoRoot
$Vcvars = "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
$SdkRoot = Get-WdkRoot
$SdkVer = "10.0.26100.0"

cmd /c "`"$Vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match "^(.*?)=(.*)$") { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
}
if ($SdkRoot) {
    if (-not (Test-Path "$SdkRoot\Include\$SdkVer\ucrt\corecrt.h")) { $SdkVer = "10.0.22621.0" }
    $env:INCLUDE = "$env:INCLUDE;$SdkRoot\Include\$SdkVer\ucrt;$SdkRoot\Include\$SdkVer\um;$SdkRoot\Include\$SdkVer\shared"
    $env:LIB = "$env:LIB;$SdkRoot\Lib\$SdkVer\ucrt\x64;$SdkRoot\Lib\$SdkVer\um\x64"
}
$env:CCACHE_DISABLE = "1"

$targets = @(
    "test-triattention-cal-v2",
    "test-triattention-prune-budget",
    "test-triattention-gpu-parity"
)

Push-Location $RepoRoot
try {
    foreach ($t in $targets) {
        Write-Host "=== Building $t ===" -ForegroundColor Cyan
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        cmake --build build --config Release -j 8 --target $t 2>&1 | Out-Host
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -ne 0) { throw "build failed for $t (exit $code)" }
    }

    $bins = @(
        "build\bin\test-triattention-cal-v2.exe",
        "build\bin\test-triattention-prune-budget.exe",
        "build\bin\test-triattention-gpu-parity.exe",
        "build\bin\Release\test-triattention-cal-v2.exe",
        "build\bin\Release\test-triattention-prune-budget.exe",
        "build\bin\Release\test-triattention-gpu-parity.exe"
    )

    foreach ($t in $targets) {
        $exe = $bins | Where-Object { $_ -match [regex]::Escape($t) } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $exe) { throw "executable not found for $t" }
        Write-Host "=== Running $exe ===" -ForegroundColor Cyan
        $dir = Split-Path $exe
        Push-Location $dir
        try {
            & ".\$(Split-Path $exe -Leaf)"
            Write-Host "EXIT $($t)=$LASTEXITCODE" -ForegroundColor $(if ($LASTEXITCODE -eq 0) { "Green" } else { "Red" })
        } finally {
            Pop-Location
        }
    }
} finally {
    Pop-Location
}
