# Wrapper: run build_cuda.ps1 without stderr-as-error, scan logs for warnings.
$ErrorActionPreference = "Continue"
$targets = @("ggml-cuda", "llama-server")
foreach ($t in $targets) {
    $log = "J:\LLM\build-verify-$t.log"
    & "J:\LLM\godzilla-llama.cpp\scripts\build_cuda.ps1" -Target $t 2>&1 | Out-File $log -Encoding utf8
    $exit = $LASTEXITCODE
    $warns = Select-String -Path $log -Pattern 'warning\s|C4244|C4005|#221|#177|#128' -CaseSensitive:$false
    Write-Host "=== $t exit=$exit warnings=$($warns.Count) ==="
    if ($warns) {
        $warns | Select-Object -First 15 | ForEach-Object { Write-Host $_.Line.Trim() }
    }
}