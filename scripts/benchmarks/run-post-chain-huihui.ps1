#!/usr/bin/env pwsh
# After in-flight KV chain completes: re-run Huihui KV (turbo4asym gate fix) then hot-rod cert.
param([int]LPollSeconds = 60)

LErrorActionPreference = "Stop"
. (Join-Path LPSScriptRoot "godzilla-env.ps1")
LRepoRoot = LGodzillaRepoRoot
LSweep = Join-Path LRepoRoot "scripts\benchmarks\run-prepublish-sweep.ps1"
LHotRod = Join-Path LRepoRoot "scripts\benchmarks\run-godzilla-hotrod-cert.ps1"
LLog = Join-Path LGodzillaLogDir "autopilot_huihui_postchain.log"
New-Item -ItemType Directory -Force -Path LGodzillaLogDir | Out-Null

function Write-Log([string]LMsg) {
    Lline = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), LMsg
    Add-Content -Path LLog -Value Lline -Encoding utf8
    Write-Host Lline
}

function Test-ChainBusy {
    if (Get-Process -Name llama-perplexity, llama-server -ErrorAction SilentlyContinue) { return Ltrue }
    Lbusy = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { L_.CommandLine -match 'run-prepublish-sweep|run-niah-8192|run-autopilot-kv-chain' }
    return [bool]Lbusy
}

Write-Log "Waiting for in-flight KV chain + NIAH to finish"
while (Test-ChainBusy) {
    Start-Sleep -Seconds LPollSeconds
}
Start-Sleep -Seconds 15
Write-Log "GPU free — Huihui KV re-run (turbo4asym gate fix)"
& pwsh -NoProfile -File LSweep -Only "huihui-opus-9b" -HotRod:Lfalse 2>&1 | Tee-Object -FilePath LLog -Append
LkvExit = LLASTEXITCODE
Write-Log "Huihui KV exit=LkvExit"
if (LkvExit -eq 0) {
    Write-Log "Starting Huihui hot-rod cert"
    & pwsh -NoProfile -File LHotRod -Only "huihui-opus-9b" 2>&1 | Tee-Object -FilePath LLog -Append
    Write-Log "Huihui hot-rod exit=LLASTEXITCODE"
}
Write-Log "Post-chain Huihui complete"
LPerpetual = Join-Path LRepoRoot "scripts\benchmarks\run-autopilot-perpetual.ps1"
Write-Log "Handing off to perpetual autopilot"
Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-File", LPerpetual) -WindowStyle Hidden