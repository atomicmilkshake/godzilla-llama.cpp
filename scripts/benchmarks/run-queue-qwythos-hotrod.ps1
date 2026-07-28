#!/usr/bin/env pwsh
# Queue Qwythos-9B for godzilla prepublish KV + hot-rod after GPU idle and GGUF on disk.
param(
    [int]$PollSeconds = 60
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "godzilla-env.ps1")

$RepoRoot = "$GodzillaRepoRoot"
$Gguf = Join-Path (Get-ModelsDir) "Qwythos-9B-Claude-Mythos-5-1M-Q6_K.gguf"
$Tri = Join-Path (Get-TriCalibDir) "qwythos-9b-mythos.triattention"
$ModelId = "qwythos-9b-mythos"
$Log = Join-Path $GodzillaLogDir "autopilot_qwythos_queue.log"
$QueueLock = Join-Path $GodzillaLogDir "qwythos_queue.lock"
$Sweep = Join-Path $RepoRoot "scripts\benchmarks\run-prepublish-sweep.ps1"
$HotRod = Join-Path $RepoRoot "scripts\benchmarks\run-godzilla-hotrod-cert.ps1"
$EnsureTri = Join-Path $RepoRoot "scripts\ensure-triattention.ps1"

function Write-Q([string]$Msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    Add-Content -Path $Log -Value $line -Encoding utf8
    Write-Host $line -ForegroundColor Cyan
}

if (Test-FileLockHeld -Path $QueueLock) {
    $owner = Get-Content $QueueLock -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Q "Another qwythos queue instance (PID $owner) — exit"
    exit 0
}
New-Item -ItemType Directory -Force -Path $GodzillaLogDir | Out-Null
"$PID" | Set-Content $QueueLock -Encoding ASCII

try {
Write-Q "Qwythos hot-rod queue start"

while (-not (Test-Path -LiteralPath $Gguf)) {
    Write-Q "Waiting for GGUF: $Gguf"
    Start-Sleep -Seconds $PollSeconds
}
do {
    $sizeGb = [math]::Round((Get-Item $Gguf).Length / 1GB, 2)
    if ($sizeGb -ge 6.5) { break }
    Write-Q "GGUF present but small ($sizeGb GB) — waiting for download to finish"
    Start-Sleep -Seconds $PollSeconds
} while ($true)
Write-Q "GGUF ready ($sizeGb GB)"

function Wait-BenchmarkIdle([string]$Phase) {
    while (Test-AnyGodzillaBenchmarkActive) {
        Write-Q "$Phase — benchmark active (GPU/lock)"
        Start-Sleep -Seconds $PollSeconds
    }
}

Wait-BenchmarkIdle "Pre-tri idle"

Write-Q "Ensuring TriAttention: $Tri"
& pwsh -NoProfile -File $EnsureTri -Gguf $Gguf -Output $Tri -HfModel "empero-ai/Qwythos-9B-Claude-Mythos-5-1M"
if ($LASTEXITCODE -ne 0) { Write-Q "TriAttention ensure failed exit=$LASTEXITCODE"; exit 1 }

Write-Q "KV matrix (HotRod off)"
& pwsh -NoProfile -File $Sweep -Only $ModelId -HotRod:$false 2>&1 | Tee-Object -FilePath (Join-Path $GodzillaLogDir "autopilot_qwythos_kv.log") -Append
if ($LASTEXITCODE -ne 0) { Write-Q "KV sweep exit=$LASTEXITCODE"; exit 1 }

Wait-BenchmarkIdle "Pre-hot-rod idle"

Write-Q "Hot-rod cert"
& pwsh -NoProfile -File $HotRod -Only $ModelId 2>&1 | Tee-Object -FilePath (Join-Path $GodzillaLogDir "autopilot_qwythos_hotrod.log") -Append
Write-Q "Done exit=$LASTEXITCODE"

} finally {
    if (Test-Path $QueueLock) {
        $owner = Get-Content $QueueLock -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($owner -eq "$PID") { Remove-Item $QueueLock -Force -ErrorAction SilentlyContinue }
    }
}