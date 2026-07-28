$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "godzilla-paths.ps1")
$RepoRoot = Get-GodzillaRepoRoot
$LogDir = Join-Path $RepoRoot "logs\build"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Vcvars = "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
cmd /c "`"$Vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match "^(.*?)=(.*)$") { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
}
$env:CCACHE_DISABLE = "1"
Push-Location $RepoRoot
try {
    $cfgLog = Join-Path $LogDir "cmake-config.log"
    cmake -S . -B build -G Ninja `
        -DGGML_CUDA=ON -DGGML_NATIVE=ON -DGGML_CUDA_FA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON `
        -DGGML_CCACHE=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86 2>&1 |
        Out-File $cfgLog
    $cfgExit = $LASTEXITCODE
    $buildLog = Join-Path $LogDir "build-ggml-full.log"
    cmake --build build --config Release -j 8 --target ggml-cuda 2>&1 |
        Out-File $buildLog
    $buildExit = $LASTEXITCODE
    Write-Host "configure=$cfgExit build=$buildExit"
    if ($buildExit -eq 0) {
        $warns = Select-String -Path $buildLog -Pattern 'warning|C4244|C4005|#221|#177|#128' -CaseSensitive:$false
        if ($warns) {
            Write-Host "WARNINGS: $($warns.Count)"
            $warns | Select-Object -First 20 | ForEach-Object { Write-Host $_.Line }
        } else {
            Write-Host "ZERO WARNINGS (ggml-cuda)"
        }
    }
} finally {
    Pop-Location
}
