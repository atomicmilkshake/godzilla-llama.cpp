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
$env:TURBO_INNERQ = "1"
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

# /health returns before large models finish loading; wait for chat API
$modelReady = $false
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        Get-Content $log -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        throw "Server exited during model load code=$($proc.ExitCode). Log: $log"
    }
    try {
        $models = Invoke-RestMethod -Uri "$base/v1/models" -TimeoutSec 5
        if ($models.data -and $models.data.Count -gt 0) { $modelReady = $true; break }
    } catch {}
    Start-Sleep -Milliseconds 500
}
if (-not $modelReady) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "Model not ready within ${LaunchTimeoutSec}s. Log: $log"
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
# Gemma4 thinking models need headroom for <|channel>thought|> + visible reply.
$maxTokens = 128
if ($Model -match 'gemma4|gemma-4') { $maxTokens = 256 }

$body = @{
    model = "gpt-3.5-turbo"
    messages = @(@{ role = "user"; content = "Reply with exactly: GODZILLA_OK" })
    max_tokens = $maxTokens
    temperature = 0.1
} | ConvertTo-Json -Depth 5

$resp = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 120
$sw.Stop()
$msg = $resp.choices[0].message
$text = $msg.content
if ([string]::IsNullOrWhiteSpace($text) -and $msg.reasoning_content) {
    $text = $msg.reasoning_content
}
Write-Host "Chat completion (${($sw.Elapsed.TotalSeconds.ToString('F1'))}s): $text" -ForegroundColor Green

function Get-StreamDeltaText {
    param([string]$Url, [hashtable]$ReqBody, [int]$TimeoutSec = 120)
    $json = $ReqBody | ConvertTo-Json -Depth 5
    $raw = (Invoke-WebRequest -Uri $Url -Method Post -Body $json -ContentType "application/json" -TimeoutSec $TimeoutSec).Content
    $content = ""
    $reasoning = ""
    foreach ($line in ($raw -split "`n")) {
        if ($line -match '^data:\s*(.+)$' -and $Matches[1] -ne '[DONE]') {
            $chunk = $Matches[1] | ConvertFrom-Json
            $delta = $chunk.choices[0].delta
            if ($delta.content) { $content += $delta.content }
            if ($delta.reasoning_content) { $reasoning += $delta.reasoning_content }
        }
    }
    return [ordered]@{ content = $content; reasoning = $reasoning }
}

$streamBody = @{
    model = "gpt-3.5-turbo"
    messages = @(@{ role = "user"; content = "Reply with exactly: GODZILLA_STREAM_OK" })
    max_tokens = $maxTokens
    temperature = 0.1
    stream = $true
}
$stream = Get-StreamDeltaText -Url "$base/v1/chat/completions" -ReqBody $streamBody
$streamText = $stream.content
if ([string]::IsNullOrWhiteSpace($streamText) -and $stream.reasoning) {
    $streamText = $stream.reasoning
}
Write-Host "Chat stream: $streamText" -ForegroundColor Green

$respBody = @{
    model = "gpt-3.5-turbo"
    input = "Reply with exactly: GODZILLA_RESP_OK"
    max_output_tokens = $maxTokens
    temperature = 0.1
}
$respApi = Invoke-RestMethod -Uri "$base/v1/responses" -Method Post -Body ($respBody | ConvertTo-Json -Depth 5) -ContentType "application/json" -TimeoutSec 120
$respMsgText = ""
$respReasonText = ""
foreach ($item in $respApi.output) {
    if ($item.type -eq 'message' -and $item.content) {
        $respMsgText += ($item.content | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { $_.text }) -join ''
    }
    if ($item.type -eq 'reasoning' -and $item.content) {
        $respReasonText += ($item.content | ForEach-Object { $_.text }) -join ''
    }
}
$respText = $respMsgText
if ([string]::IsNullOrWhiteSpace($respText) -and $respReasonText) {
    $respText = $respReasonText
}
Write-Host "Responses API: $respText" -ForegroundColor Green

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
$preview = if ($text.Length -gt 0) { ($text -replace "`n", " ").Substring(0, [math]::Min(200, $text.Length)) } else { "" }
$result = [ordered]@{
    status = "pass"
    port = $Port
    cache_k = $CacheK
    cache_v = $CacheV
    tri_stats = $TriStats
    latency_sec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    response_preview = $preview
    chat_stream_preview = if ($streamText.Length -gt 0) { ($streamText -replace "`n", " ").Substring(0, [math]::Min(200, $streamText.Length)) } else { "" }
    responses_preview = if ($respText.Length -gt 0) { ($respText -replace "`n", " ").Substring(0, [math]::Min(200, $respText.Length)) } else { "" }
    log = $log
    probed_at = (Get-Date).ToUniversalTime().ToString("o")
}
$out = Join-Path $logDir "launch_smoke_$ts.json"
$result | ConvertTo-Json -Depth 4 | Set-Content $out -Encoding UTF8
Write-Host "Wrote $out" -ForegroundColor Gray
if ($text -notmatch "GODZILLA|OK|ok") {
    Write-Host "WARN: unexpected chat completion text" -ForegroundColor Yellow
}
if ($streamText -notmatch "GODZILLA|STREAM|OK|ok") {
    Write-Host "WARN: unexpected chat stream text" -ForegroundColor Yellow
}
if ($respText -notmatch "GODZILLA|RESP|OK|ok") {
    Write-Host "WARN: unexpected responses API text" -ForegroundColor Yellow
}