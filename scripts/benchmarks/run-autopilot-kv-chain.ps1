#!/usr/bin/env pwsh
# Wait for active perplexity, then run remaining KV sweep models + NIAH 8192 reverify.
param(
    [int]$PollSeconds = 60
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "godzilla-env.ps1")
$RepoRoot = $GodzillaRepoRoot
$Sweep = Join-Path $RepoRoot "scripts\benchmarks\run-prepublish-sweep.ps1"
$Niah = Join-Path $RepoRoot "scripts\benchmarks\run-niah-8192-reverify.ps1"
$Log = Join-Path $GodzillaLogDir "autopilot_kv_chain.log"
New-Item -ItemType Directory -Force -Path $GodzillaLogDir | Out-Null

function Write-Chain([string]$Msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    try {
        Add-Content -Path $Log -Value $line -Encoding utf8 -ErrorAction Stop
    } catch {
        # Tee-Object or a parallel chain may hold the log; console is still canonical.
    }
    Write-Host $line
}

Write-Chain "AUTOPILOT KV CHAIN: waiting for llama-perplexity to finish"
while (Get-Process -Name llama-perplexity -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds $PollSeconds
}
Write-Chain "GPU free — starting huihui + 30B KV sweep"
& pwsh -NoProfile -File $Sweep -Only "huihui-opus-9b,qwen3-coder-30b" -HotRod:$false 2>&1 | Tee-Object -FilePath (Join-Path $GodzillaLogDir "autopilot_kv_huihui_30b.log") -Append
Write-Chain "KV sweep exit=$LASTEXITCODE"

Write-Chain "Starting NIAH 8192 reverify (9B + 4B)"
& pwsh -NoProfile -File $Niah 2>&1 | Tee-Object -FilePath (Join-Path $GodzillaLogDir "autopilot_niah_8192.log") -Append
Write-Chain "NIAH reverify exit=$LASTEXITCODE"
Write-Chain "AUTOPILOT KV CHAIN complete"