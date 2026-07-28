$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "godzilla-paths.ps1")
$RepoRoot = Get-GodzillaRepoRoot
$LogDir = Join-Path $RepoRoot "logs\build"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Vcvars = "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
cmd /c "`"$Vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match "^(.*?)=(.*)$") { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
}
$SdkVer = "10.0.26100.0"
$SdkRoot = Get-WdkRoot
if ($SdkRoot) {
    $env:INCLUDE = "$env:INCLUDE;$SdkRoot\Include\$SdkVer\ucrt"
    $env:LIB     = "$env:LIB;$SdkRoot\Lib\$SdkVer\ucrt\x64"
}

Push-Location $RepoRoot
try {
    $targets = @(
        "test-triattention-cal-v2",
        "test-triattention-prune-budget",
        "test-triattention-gpu-parity",
        "test-triattention-modes"
    )
    $buildLog = Join-Path $LogDir "build-tri-tests.log"
    cmake --build build --config Release -j 8 --target $targets 2>&1 | Out-File $buildLog
    $buildExit = $LASTEXITCODE
    Write-Host "build exit=$buildExit"

    $bin = Join-Path $RepoRoot "build\bin"
    foreach ($t in $targets) {
        $exe = Join-Path $bin "$t.exe"
        if (-not (Test-Path $exe)) {
            Write-Host "MISSING $t"
            continue
        }
        $runLog = Join-Path $LogDir "run-$t.log"
        & $exe 2>&1 | Tee-Object -FilePath $runLog
        Write-Host "$t exit=$LASTEXITCODE"
    }
} finally {
    Pop-Location
}
