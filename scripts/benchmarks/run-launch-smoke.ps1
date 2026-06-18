#!/usr/bin/env pwsh
# Launch godzilla llama-server, wait for /health, run one completion, tear down.
param(
    [string]$Binary = "J:\LLM\godzilla-llama.cpp\build\bin\llama-server.exe",
    [string]$Model = "J:\MOODLES\VibeThinker-3B.i1-Q4_K_M.gguf",
    [string]$TriStats = "",
    [int]$Port = 8095,
    [int]$Ctx = 8192,
    [string]$CacheK = "turbo3",
    [string]$CacheV = "turbo4",
    [int]$LaunchTimeoutSec = 120
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $Binary)) { throw "Missing binary: $Binary" }
if (-not (Test-Path $Model)) { throw "Missing model: $Model" }

Get-Process *llama-server* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$logDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "logs\benchmarks"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$log = Join-Path $logDir "launch_smoke_$ts.log"

$args = @(
    "-m", $Model,
    "-ngl", "99",
    "--flash-attn", "on",
    "-ctk", $CacheK,
    "-ctv", $CacheV,
    "-c", "$Ctx",
    "--host", "127.0.0.1",
    "--port", "$Port",
    "--jinja",
    "--temp", "1.0",
    "--top-p", "0.95"
)
if ($TriStats -and (Test-Path $TriStats)) {
    $args += @(
        "--triattention-stats", $TriStats,
        "--triattention-budget", "8192",
        "--triattention-window", "128",
        "--triattention-hard-prefix", "4096"
    )
}

Write-Host "Starting: $Binary $($args -join ' ')" -ForegroundColor Cyan
$proc = Start-Process -FilePath $Binary -ArgumentList $args -PassThru -RedirectStandardOutput $log -RedirectStandardError "${log}.err" -WindowStyle Hidden

$base = "http://127.0.0.1:$Port"
$deadline = (Get-Date).AddSeconds($LaunchTimeoutSec)
$ready = $false
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        Get-Content $log -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        throw "Server exited early code=$($proc.ExitCode). Log: $log"
    }
    try {
        $r = Invoke-WebRequest -Uri "$base/health" -TimeoutSec 3 -UseBasicParsing
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
    Start-Sleep -Milliseconds 500
}
if (-not $ready) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "Server not ready within ${LaunchTimeoutSec}s. Log: $log"
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$body = @{
    model = "gpt-3.5-turbo"
    messages = @(@{ role = "user"; content = "Reply with exactly: GODZILLA_OK" })
    max_tokens = 32
    temperature = 0.1
} | ConvertTo-Json -Depth 5

$resp = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 60
$sw.Stop()
$text = $resp.choices[0].message.content
Write-Host "Completion (${($sw.Elapsed.TotalSeconds.ToString('F1'))}s): $text" -ForegroundColor Green

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
$result = [ordered]@{
    status = "pass"
    port = $Port
    cache_k = $CacheK
    cache_v = $CacheV
    tri_stats = $TriStats
    latency_sec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    response_preview = ($text -replace "`n", " ").Substring(0, [math]::Min(200, $text.Length))
    log = $log
    probed_at = (Get-Date).ToUniversalTime().ToString("o")
}
$out = Join-Path $logDir "launch_smoke_$ts.json"
$result | ConvertTo-Json -Depth 4 | Set-Content $out -Encoding UTF8
Write-Host "Wrote $out" -ForegroundColor Gray
if ($text -notmatch "GODZILLA|OK|ok") {
    Write-Host "WARN: unexpected completion text" -ForegroundColor Yellow
}