#!/usr/bin/env pwsh
# After in-flight KV chain completes: re-run Huihui KV (turbo4asym gate fix) then hot-rod cert.
param([int]$PollSeconds = 60)

$ErrorActionPreference = "Stop"
$RepoRoot = "J:\LLM\godzilla-llama.cpp"
$Sweep = Join-Path $RepoRoot "scripts\benchmarks\run-prepublish-sweep.ps1"
$HotRod = Join-Path $RepoRoot "scripts\benchmarks\run-godzilla-hotrod-cert.ps1"
$Log = "J:\LLM\autopilot_huihui_postchain.log"

function Write-Log([string]$Msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    Add-Content -Path $Log -Value $line -Encoding utf8
    Write-Host $line
}

function Test-ChainBusy {
    if (Get-Process -Name llama-perplexity, llama-server -ErrorAction SilentlyContinue) { return $true }
    $busy = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'run-prepublish-sweep|run-niah-8192|run-autopilot-kv-chain' }
    return [bool]$busy
}

Write-Log "Waiting for in-flight KV chain + NIAH to finish"
while (Test-ChainBusy) {
    Start-Sleep -Seconds $PollSeconds
}
Start-Sleep -Seconds 15
Write-Log "GPU free — Huihui KV re-run (turbo4asym gate fix)"
& pwsh -NoProfile -File $Sweep -Only "huihui-opus-9b" -HotRod:$false 2>&1 | Tee-Object -FilePath $Log -Append
$kvExit = $LASTEXITCODE
Write-Log "Huihui KV exit=$kvExit"
if ($kvExit -eq 0) {
    Write-Log "Starting Huihui hot-rod cert"
    & pwsh -NoProfile -File $HotRod -Only "huihui-opus-9b" 2>&1 | Tee-Object -FilePath $Log -Append
    Write-Log "Huihui hot-rod exit=$LASTEXITCODE"
}
Write-Log "Post-chain Huihui complete"
$Perpetual = Join-Path $RepoRoot "scripts\benchmarks\run-autopilot-perpetual.ps1"
Write-Log "Handing off to perpetual autopilot"
Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-File", $Perpetual) -WindowStyle Hidden