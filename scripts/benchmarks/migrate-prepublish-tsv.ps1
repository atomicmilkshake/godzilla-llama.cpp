#!/usr/bin/env pwsh
$SummaryPath = "J:\LLM\godzilla-llama.cpp\logs\benchmarks\prepublish_sweep_summary.tsv"
$TsvHeader = "model_id`tlabel`tcommit`tkv_gate`thotrod`tartifact`tnotes"
if (-not (Test-Path $SummaryPath)) {
    $TsvHeader | Set-Content $SummaryPath -Encoding UTF8
    exit 0
}
$first = Get-Content $SummaryPath -TotalCount 1 -Encoding UTF8
if ($first -eq $TsvHeader) { Write-Host "Already migrated"; exit 0 }
$out = [System.Collections.Generic.List[string]]::new()
$out.Add($TsvHeader)
foreach ($row in Get-Content $SummaryPath -Encoding UTF8 | Select-Object -Skip 1) {
    if ([string]::IsNullOrWhiteSpace($row)) { continue }
    $cols = $row -split "`t"
    if ($cols.Count -eq 6) {
        $out.Add(("{0}`t{1}`t{2}`t{3}`tSKIP`t{4}`t{5}" -f $cols[0], $cols[1], $cols[2], $cols[3], $cols[4], $cols[5]))
    } elseif ($cols.Count -ge 7) {
        $out.Add($row)
    }
}
# Dedupe: keep last row per model_id
$deduped = [System.Collections.Generic.List[string]]::new()
$deduped.Add($TsvHeader)
$seen = [System.Collections.Generic.List[string]]::new()
foreach ($row in ($out | Select-Object -Skip 1)) {
    $id = ($row -split "`t")[0]
    if ($seen -contains $id) {
        $idx = $deduped.FindIndex({ param($r) ($r -split "`t")[0] -eq $id })
        if ($idx -ge 0) { $deduped[$idx] = $row }
    } else {
        $deduped.Add($row)
        $seen.Add($id)
    }
}
$deduped | Set-Content $SummaryPath -Encoding UTF8
Write-Host "Migrated $($deduped.Count - 1) rows (deduped)"