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

# prepublish_sweep_summary.tsv: 7 columns (BENCH-01 schema)
$script:PrepublishSweepTsvHeader = "model_id`tlabel`tcommit`tkv_gate`thotrod`tartifact`tnotes"
$script:PrepublishSweepTsvColCount = 7

function Get-PrepublishSweepTsvHeader {
    return $script:PrepublishSweepTsvHeader
}

function Convert-PrepublishSweepLegacyRow {
    param([string]$Row)
    if ([string]::IsNullOrWhiteSpace($Row)) { return $null }
    $cols = $Row -split "`t"
    if ($cols.Count -eq $script:PrepublishSweepTsvColCount) { return $Row }
    if ($cols.Count -eq 6) {
        return ("{0}`t{1}`t{2}`t{3}`tSKIP`t{4}`t{5}" -f $cols[0], $cols[1], $cols[2], $cols[3], $cols[4], $cols[5])
    }
    throw "prepublish_sweep_summary.tsv row for '$($cols[0])' has $($cols.Count) columns; expected $script:PrepublishSweepTsvColCount (legacy 6-col rows are migrated automatically)."
}

function Ensure-PrepublishSweepTsvSchema {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    $header = Get-PrepublishSweepTsvHeader
    if (-not (Test-Path $Path)) {
        $header | Set-Content $Path -Encoding UTF8
        return
    }
    $lines = Get-Content $Path -Encoding UTF8
    if ($lines.Count -eq 0) {
        $header | Set-Content $Path -Encoding UTF8
        return
    }
    $startIdx = 0
    if ($lines[0] -eq $header) {
        $startIdx = 1
    } elseif (($lines[0] -split "`t").Count -eq 6 -and ($lines[0] -split "`t")[0] -eq 'model_id') {
        # Legacy 6-column header without hotrod column
        $startIdx = 1
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add($header)
    foreach ($row in ($lines | Select-Object -Skip $startIdx)) {
        $normalized = Convert-PrepublishSweepLegacyRow -Row $row
        if ($normalized) { $out.Add($normalized) }
    }
    if ($lines[0] -ne $header -or $out.Count -ne ($lines.Count - $startIdx + 1)) {
        $out | Set-Content $Path -Encoding UTF8
    }
}

function Upsert-PrepublishSweepTsvRow {
    param(
        [string]$Path,
        [string]$ModelId,
        [string]$Row
    )
    $normalized = Convert-PrepublishSweepLegacyRow -Row $Row
    if (($normalized -split "`t").Count -ne $script:PrepublishSweepTsvColCount) {
        throw "Upsert row for '$ModelId' must have $script:PrepublishSweepTsvColCount tab-separated columns."
    }
    Ensure-PrepublishSweepTsvSchema -Path $Path
    $lines = Get-Content $Path -Encoding UTF8
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add($lines[0])
    $replaced = $false
    foreach ($line in $lines | Select-Object -Skip 1) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $id = ($line -split "`t")[0]
        if ($id -eq $ModelId) {
            if (-not $replaced) { $out.Add($normalized); $replaced = $true }
        } else {
            $out.Add((Convert-PrepublishSweepLegacyRow -Row $line))
        }
    }
    if (-not $replaced) { $out.Add($normalized) }
    $out | Set-Content $Path -Encoding UTF8
}

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
