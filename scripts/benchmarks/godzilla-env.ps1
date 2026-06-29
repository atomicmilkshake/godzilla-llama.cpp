#!/usr/bin/env pwsh
# Shared Godzilla benchmark environment (dot-source from runners).
. (Join-Path $PSScriptRoot "..\godzilla-paths.ps1")

$script:GodzillaRepoRoot = Get-GodzillaRepoRoot
$script:SomsRoot = Get-SomsRoot
$script:GodzillaLogDir = Join-Path $GodzillaRepoRoot "logs\benchmarks"
$script:GodzillaGpuLockPath = Join-Path $GodzillaLogDir "godzilla_gpu.lock"
$script:PrepublishSweepLockPath = Join-Path $GodzillaLogDir "prepublish_sweep.lock"
$script:GemmaAutopilotLockPath = Join-Path $GodzillaLogDir "gemma4_coding_autopilot.lock"
$script:HotrodCertLockPath = if ($SomsRoot) {
    Join-Path $SomsRoot "logs\godzilla_hotrod.cert.lock"
} else {
    Join-Path $GodzillaLogDir "godzilla_hotrod.cert.lock"
}
$env:TURBO_INNERQ = "1"

function Get-GodzillaBinDir {
    Join-Path $GodzillaRepoRoot "build\bin"
}

function Test-GodzillaGpuProcessRunning {
    return [bool](Get-Process -Name llama-perplexity, llama-server -ErrorAction SilentlyContinue)
}

function Wait-GodzillaGpuFree {
    param(
        [int]$PollSeconds = 15,
        [scriptblock]$OnWait = $null
    )
    while (Test-GodzillaGpuProcessRunning) {
        if ($OnWait) { & $OnWait }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Test-FileLockHeld {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $line = Get-Content $Path -ErrorAction SilentlyContinue | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
        return $false
    }
    $ownerPid = ($line -split ':', 2)[0]
    $pidNum = 0
    [void][int]::TryParse($ownerPid, [ref]$pidNum)
    if ($pidNum -and (Get-Process -Id $pidNum -ErrorAction SilentlyContinue)) { return $true }
    Remove-Item $Path -Force -ErrorAction SilentlyContinue
    return $false
}

function Test-GodzillaGpuLockHeld {
    return (Test-FileLockHeld -Path $GodzillaGpuLockPath)
}

function Test-AnyGodzillaBenchmarkActive {
    if (Test-GodzillaGpuProcessRunning) { return $true }
    if (Test-GodzillaGpuLockHeld) { return $true }
    if (Test-FileLockHeld -Path $PrepublishSweepLockPath) { return $true }
    if (Test-FileLockHeld -Path $GemmaAutopilotLockPath) { return $true }
    if (Test-FileLockHeld -Path $HotrodCertLockPath) { return $true }
    return $false
}

function Enter-GodzillaGpuLock {
    param(
        [string]$Operation = "benchmark",
        [switch]$Wait
    )
    if ($Wait) {
        Wait-GodzillaGpuFree -OnWait { Write-Host "  GPU busy — waiting..." -ForegroundColor DarkYellow }
    } elseif (Test-AnyGodzillaBenchmarkActive) {
        throw "GPU or benchmark lock already active — refuse concurrent major GPU work ($Operation)"
    }
    New-Item -ItemType Directory -Force -Path $GodzillaLogDir | Out-Null
    if (Test-GodzillaGpuLockHeld) {
        throw "godzilla_gpu.lock already held"
    }
    "${PID}:${Operation}" | Set-Content $GodzillaGpuLockPath -Encoding ASCII
}

function Exit-GodzillaGpuLock {
    if (-not (Test-Path $GodzillaGpuLockPath)) { return }
    $line = Get-Content $GodzillaGpuLockPath -ErrorAction SilentlyContinue | Select-Object -First 1
    $owner = ($line -split ':')[0]
    if ($owner -eq "$PID") { Remove-Item $GodzillaGpuLockPath -Force -ErrorAction SilentlyContinue }
}
