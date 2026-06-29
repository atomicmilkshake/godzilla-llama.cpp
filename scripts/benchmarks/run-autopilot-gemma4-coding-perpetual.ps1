#!/usr/bin/env pwsh
# Perpetual autopilot: gemma4-coding KV + hot-rod cert until CERTIFIED (operator priority).
param(
    [int]$PollSeconds = 30,
    [int]$CycleSleepMinutes = 5
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "godzilla-env.ps1")

$RepoRoot = "$GodzillaRepoRoot"
$Journal = "$env:GODZILLA_OPERATOR_JOURNAL"
$Log = Join-Path $GodzillaLogDir "autopilot_gemma4_coding_perpetual.log"
$ModelPath = Join-Path (Get-ModelsDir) "gemma4-coding-Q4_K_M.gguf"
$TriStats = Join-Path (Get-TriCalibDir) "gemma4/gemma4-coding-v2.triattention"
$ModelId = "gemma4-coding"
$PresetId = "Gemma4-12B-Coder Fable5-Composer2.5 (Q4_K_M)"

$KvScript = Join-Path $RepoRoot "scripts\benchmarks\run-kv-matrix.ps1"
$HotRodScript = Join-Path $RepoRoot "scripts\benchmarks\run-godzilla-hotrod-cert.ps1"
$PreflightScript = Join-Path $RepoRoot "scripts\benchmarks\run-engine-preflight.ps1"
$SmokeScript = Join-Path $RepoRoot "scripts\benchmarks\run-launch-smoke.ps1"
$HotrodSummary = Join-Path $RepoRoot "logs\benchmarks\prepublish_hotrod_summary.tsv"
$KvSummary = Join-Path $RepoRoot "logs\benchmarks\prepublish_sweep_summary.tsv"
$LockFile = Join-Path $RepoRoot "logs\benchmarks\gemma4_coding_autopilot.lock"

function Write-Auto([string]$Msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    try { Add-Content -Path $Log -Value $line -Encoding utf8 } catch { }
    Write-Host $line -ForegroundColor Cyan
}

function Test-Certified {
    if (-not (Test-Path $HotrodSummary)) { return $false }
    $rows = Import-Csv $HotrodSummary -Delimiter "`t" -ErrorAction SilentlyContinue
    $hit = $rows | Where-Object { $_.model_id -eq $ModelId -and $_.hotrod_cert -eq "CERTIFIED" } | Select-Object -Last 1
    if ($hit) {
        $peak = 0
        if ($hit.peak_he -match '^(\d+)/') { $peak = [int]$Matches[1] }
        return ($peak -ge 28)
    }
    return $false
}

function Wait-GpuFree {
    Wait-GodzillaGpuFree -PollSeconds $PollSeconds -OnWait { Write-Auto "GPU busy — wait ${PollSeconds}s" }
}

function Update-KvSummaryPass([string]$Artifact) {
    $commit = git -C $RepoRoot rev-parse --short HEAD 2>$null
    if (-not (Test-Path $KvSummary)) {
        "model_id`tlabel`tcommit`tkv_gate`thotrod`tartifact`tnotes" | Set-Content $KvSummary -Encoding UTF8
    }
    Add-Content $KvSummary "$ModelId`t$PresetId Q4_K_M`t$commit`tPASS`tQUEUED`t$Artifact`tautopilot_kv_pass"
}

if (Test-Path $LockFile) {
    $lp = 0
    [void][int]::TryParse((Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$lp)
    if ($lp -and (Get-Process -Id $lp -ErrorAction SilentlyContinue)) {
        Write-Auto "Another gemma4 autopilot instance (PID $lp) — exit"
        exit 0
    }
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
if (Test-FileLockHeld -Path $PrepublishSweepLockPath) {
    Write-Auto "prepublish sweep active — gemma4 autopilot deferred"
    exit 0
}
if (Test-FileLockHeld -Path (Join-Path $RepoRoot "logs\benchmarks\autopilot_perpetual.lock")) {
    Write-Auto "prepublish autopilot active — gemma4 autopilot deferred"
    exit 0
}
$PID | Set-Content $LockFile -Encoding ascii

try {
    Write-Auto "GEMMA4-CODING PERPETUAL AUTOPILOT start"

    if (Test-Certified) {
        Write-Auto "Already CERTIFIED — exit"
        exit 0
    }

    $cycle = 0
    while ($true) {
        $cycle++
        Write-Auto "=== Cycle $cycle ==="
        Wait-GpuFree

        Write-Auto "Preflight gate"
        & pwsh -NoProfile -File $PreflightScript 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Auto "Preflight FAIL exit=$LASTEXITCODE — rebuild required; sleep 10m"
            Start-Sleep -Seconds 600
            continue
        }

        if (-not (Test-Path -LiteralPath $ModelPath)) {
            Write-Auto "FATAL: GGUF missing $ModelPath"
            exit 1
        }

        $kvLog = Join-Path $RepoRoot ("logs\benchmarks\autopilot_gemma4_kv_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
        Write-Auto "KV matrix"
        $kvArgs = @('-NoProfile', '-File', $KvScript, '-Model', $ModelPath, '-CtxSize', '512', '-IncludeKvarn')
        if (Test-Path -LiteralPath $TriStats) { $kvArgs += @('-TriStats', $TriStats) }
        & pwsh @kvArgs 2>&1 | Tee-Object -FilePath $kvLog
        $kvExit = $LASTEXITCODE
        $artifact = ""
        $rl = Select-String -Path $kvLog -Pattern 'Results:\s+(.+)$' | Select-Object -Last 1
        if ($rl) { $artifact = Split-Path $rl.Matches[0].Groups[1].Value.Trim() -Leaf }
        if ($kvExit -eq 0) {
            Update-KvSummaryPass $artifact
            Write-Auto "KV PASS artifact=$artifact"
        } else {
            Write-Auto "KV exit=$kvExit (hot-rod still runs — ISWA waiver may apply next run)"
        }

        Wait-GpuFree
        Write-Auto "Launch smoke (turbo3-turbo4-tri-8k)"
        if (Test-Path $SmokeScript) {
            & pwsh -NoProfile -File $SmokeScript -Model $ModelPath -TriStats $TriStats -Ctx 8192 -CacheK turbo3 -CacheV turbo4 -LaunchTimeoutSec 300 2>&1 |
                Tee-Object -FilePath ($kvLog + ".smoke") -Append
            if ($LASTEXITCODE -ne 0) {
                Write-Auto "Smoke FAIL exit=$LASTEXITCODE — retry next cycle"
                Start-Sleep -Seconds ($CycleSleepMinutes * 60)
                continue
            }
        }

        Wait-GpuFree
        Write-Auto "Hot-rod cert §5"
        Remove-Item $HotrodCertLockPath -Force -ErrorAction SilentlyContinue
        & pwsh -NoProfile -File $HotRodScript -Only $ModelId 2>&1 |
            Tee-Object -FilePath ($kvLog + ".hotrod") -Append
        $hotrodExit = $LASTEXITCODE

        if (Test-Certified) {
            $note = @"
## $(Get-Date -Format 'yyyy-MM-dd HH:mm') — gemma4-coding CERTIFIED (perpetual autopilot)

- Cycle: $cycle
- KV exit: $kvExit
- Hot-rod exit: $hotrodExit
- Summary: $HotrodSummary
"@
            Add-Content -Path $Journal -Value $note -Encoding utf8
            Write-Auto "SUCCESS: gemma4-coding CERTIFIED"
            exit 0
        }

        Write-Auto "NOT_CERTIFIED yet (hotrod exit=$hotrodExit) — sleep ${CycleSleepMinutes}m and retry"
        Start-Sleep -Seconds ($CycleSleepMinutes * 60)
    }
} finally {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}