# Wrapper: run build_cuda.ps1 without stderr-as-error, scan logs for warnings.
$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "godzilla-paths.ps1")
$RepoRoot = Get-GodzillaRepoRoot
$LogDir = Join-Path $RepoRoot "logs\build"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$buildScript = Join-Path $RepoRoot "scripts\build_cuda.ps1"
$targets = @("ggml-cuda", "llama-server")
foreach ($t in $targets) {
    $log = Join-Path $LogDir "build-verify-$t.log"
    & $buildScript -Target $t 2>&1 | Out-File $log -Encoding utf8
    $exit = $LASTEXITCODE
    $warns = Select-String -Path $log -Pattern 'warning\s|C4244|C4005|#221|#177|#128' -CaseSensitive:$false
    Write-Host "=== $t exit=$exit warnings=$($warns.Count) ==="
    if ($warns) {
        $warns | Select-Object -First 15 | ForEach-Object { Write-Host $_.Line.Trim() }
    }
}
