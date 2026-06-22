#!/usr/bin/env pwsh
# Continuous prepublish autopilot: KV reruns, hot-rod cert, NIAH reverify, TSV/journal updates.
param(
    [int]$PollSeconds = 60,
    [int]$CycleSleepMinutes = 10,
    [switch]$SingleCycle
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "godzilla-env.ps1")
$RepoRoot = "J:\LLM\godzilla-llama.cpp"
$AutopilotLockPath = Join-Path $GodzillaLogDir "autopilot_perpetual.lock"
$Journal = "J:\LLM\agent-journal.md"
$Log = "J:\LLM\autopilot_perpetual.log"
$Sweep = Join-Path $RepoRoot "scripts\benchmarks\run-prepublish-sweep.ps1"
$HotRod = Join-Path $RepoRoot "scripts\benchmarks\run-godzilla-hotrod-cert.ps1"
$Niah = Join-Path $RepoRoot "scripts\benchmarks\run-niah-8192-reverify.ps1"
$KvSummary = Join-Path $RepoRoot "logs\benchmarks\prepublish_sweep_summary.tsv"
$HotrodSummary = Join-Path $RepoRoot "logs\benchmarks\prepublish_hotrod_summary.tsv"

# Models to re-KV after harness fixes (turbo4asym gate, kvarn crash waivers, etc.)
$KvRerunIds = @("huihui-opus-9b")

# Priority KV targets (operator queue — newest first when not certified)
# qwythos-9b-mythos: dedicated run-queue-qwythos-hotrod.ps1 (tri + KV + hot-rod serial)
$PriorityKvIds = @()

# KV FAIL quality/arch ceilings — documented, not engine-fixable this sweep
$KvCeilingIds = @("lfm25-8b", "qwen3-coder-30b", "vibethinker-3b", "huihui-gemma-4-12b")

# Hot-rod ceilings — blocked models or repeated NOT_CERTIFIED (incl. peak 0)
# gemma4-coding: operator lifted ceiling 2026-06-21 — hot-rod cert in flight
$HotrodCeilingIds = @("gemma4-31b")

function Write-Auto([string]$Msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    try { Add-Content -Path $Log -Value $line -Encoding utf8 -ErrorAction Stop } catch { }
    Write-Host $line
}

function Wait-GpuFree {
    Wait-GodzillaGpuFree -PollSeconds $PollSeconds -OnWait { Write-Auto "GPU busy — waiting ${PollSeconds}s" }
}

function Get-LatestKvRows {
    if (-not (Test-Path $KvSummary)) { return @{} }
    $map = @{}
    Import-Csv $KvSummary -Delimiter "`t" | ForEach-Object {
        $map[$_.model_id] = $_  # last row wins (upserted TSV keeps one row per model)
    }
    return $map
}

function Get-CertifiedIds {
    if (-not (Test-Path $HotrodSummary)) { return @() }
    $latest = @{}
    Import-Csv $HotrodSummary -Delimiter "`t" | ForEach-Object {
        $latest[$_.model_id] = $_
    }
    @($latest.Values | Where-Object { $_.hotrod_cert -eq "CERTIFIED" } | ForEach-Object { $_.model_id })
}

function Get-LatestHotrodRows {
    if (-not (Test-Path $HotrodSummary)) { return @{} }
    $map = @{}
    Import-Csv $HotrodSummary -Delimiter "`t" | ForEach-Object {
        $id = $_.model_id
        $peak = 0
        if ($_.peak_he -match '^(\d+)/') { $peak = [int]$Matches[1] }
        if (-not $map.ContainsKey($id) -or $peak -gt $map[$id].Peak) {
            $map[$id] = [PSCustomObject]@{ Peak = $peak; Cert = $_.hotrod_cert; Row = $_ }
        }
    }
    return $map
}

function Test-HotrodCeiling {
    param([string]$ModelId, $HotrodRows)
    if ($HotrodCeilingIds -contains $ModelId) { return $true }
    if (-not $HotrodRows.ContainsKey($ModelId)) { return $false }
    $h = $HotrodRows[$ModelId]
    return ($h.Cert -eq "NOT_CERTIFIED" -and ($h.Peak -eq 0 -or $h.Peak -lt 28))
}

function Append-JournalNote([string]$Note) {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    $block = @"

## $stamp — Autopilot perpetual cycle

$Note

"@
    Add-Content -Path $Journal -Value $block -Encoding utf8
}

if (Test-FileLockHeld -Path $AutopilotLockPath) {
    $lp = Get-Content $AutopilotLockPath -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Auto "Another autopilot perpetual instance (PID $lp) — exit"
    exit 0
}
$PID | Set-Content $AutopilotLockPath -Encoding ASCII

Write-Auto "AUTOPILOT PERPETUAL start (single=$SingleCycle)"

try {
do {
    $cycleNotes = [System.Collections.Generic.List[string]]::new()
    Wait-GpuFree
    if (Test-FileLockHeld -Path $GemmaAutopilotLockPath) {
        Write-Auto "gemma4 autopilot active — skip cycle"
        if ($SingleCycle) { break }
        Start-Sleep -Seconds ($CycleSleepMinutes * 60)
        continue
    }

    $kvRows = Get-LatestKvRows
    $certIds = Get-CertifiedIds
    $hotrodRows = Get-LatestHotrodRows

    # --- Priority new-wave KV (fablevibes + huihui-gemma) ---
    $priorityTargets = @($PriorityKvIds | Where-Object {
        $certIds -notcontains $_ -and (
            -not $kvRows.ContainsKey($_) -or $kvRows[$_].kv_gate -ne "PASS"
        )
    })
    if ($priorityTargets.Count -gt 0) {
        Write-Auto "Priority KV: $($priorityTargets -join ', ')"
        & pwsh -NoProfile -File $Sweep -Only ($priorityTargets -join ',') -HotRod:$false 2>&1 |
            Tee-Object -FilePath "J:\LLM\autopilot_kv_priority_perpetual.log" -Append
        $cycleNotes.Add("Priority KV $($priorityTargets -join ',') exit=$LASTEXITCODE")
        $kvRows = Get-LatestKvRows
    }

    # --- KV reruns for harness-fixed models still showing FAIL ---
    $kvTargets = @($KvRerunIds | Where-Object {
        -not $kvRows.ContainsKey($_) -or $kvRows[$_].kv_gate -ne "PASS"
    })
    if ($kvTargets.Count -gt 0) {
        Write-Auto "KV rerun: $($kvTargets -join ', ')"
        & pwsh -NoProfile -File $Sweep -Only ($kvTargets -join ',') -HotRod:$false 2>&1 |
            Tee-Object -FilePath "J:\LLM\autopilot_kv_rerun_perpetual.log" -Append
        $cycleNotes.Add("KV rerun $($kvTargets -join ',') exit=$LASTEXITCODE")
        $kvRows = Get-LatestKvRows
    }

    # --- Hot-rod cert for KV PASS models not yet CERTIFIED (skip known ceilings) ---
    $hotrodTargets = @(
        $kvRows.GetEnumerator() |
            Where-Object {
                $_.Value.kv_gate -eq "PASS" -and
                $certIds -notcontains $_.Key -and
                -not (Test-HotrodCeiling -ModelId $_.Key -HotrodRows $hotrodRows)
            } |
            ForEach-Object { $_.Key }
    )
    if ($hotrodTargets.Count -gt 0) {
        Wait-GpuFree
        Write-Auto "Hot-rod cert: $($hotrodTargets -join ', ')"
        & pwsh -NoProfile -File $HotRod -Only ($hotrodTargets -join ',') 2>&1 |
            Tee-Object -FilePath "J:\LLM\autopilot_hotrod_perpetual.log" -Append
        $cycleNotes.Add("Hot-rod $($hotrodTargets -join ',') exit=$LASTEXITCODE")
    }

    # NIAH 8192: disabled in perpetual loop until harness HTTP 400 is fixed (was burning GPU for no gain)

    # --- KV sweep for FAIL models not on documented ceiling list ---
    $pendingKv = @(
        $kvRows.GetEnumerator() |
            Where-Object {
                $_.Value.kv_gate -eq "FAIL" -and
                $KvRerunIds -notcontains $_.Key -and
                $KvCeilingIds -notcontains $_.Key
            } |
            ForEach-Object { $_.Key }
    )
    if ($pendingKv.Count -gt 0) {
        Wait-GpuFree
        Write-Auto "Pending KV sweep: $($pendingKv -join ', ')"
        & pwsh -NoProfile -File $Sweep -Only ($pendingKv -join ',') -HotRod:$false 2>&1 |
            Tee-Object -FilePath "J:\LLM\autopilot_kv_pending_perpetual.log" -Append
        $cycleNotes.Add("Pending KV $($pendingKv -join ',') exit=$LASTEXITCODE")
    }

    if ($cycleNotes.Count -gt 0) {
        Append-JournalNote ($cycleNotes -join "`n")
        Write-Auto "Cycle done: $($cycleNotes -join '; ')"
    } else {
        Write-Auto "Cycle idle — no pending work"
    }

    if ($SingleCycle) { break }
    if ($cycleNotes.Count -eq 0) {
        Write-Auto "No pending work — perpetual idle exit"
        break
    }
    Write-Auto "Sleeping ${CycleSleepMinutes}m before next cycle"
    Start-Sleep -Seconds ($CycleSleepMinutes * 60)
} while ($true)

} finally {
    if (Test-Path $AutopilotLockPath) {
        $owner = Get-Content $AutopilotLockPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($owner -eq "$PID") { Remove-Item $AutopilotLockPath -Force -ErrorAction SilentlyContinue }
    }
}

Write-Auto "AUTOPILOT PERPETUAL exit"