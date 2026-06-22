#!/usr/bin/env pwsh
$p = "J:\LLM\godzilla-llama.cpp\logs\benchmarks\prepublish_sweep_summary.tsv"
$h = "model_id`tlabel`tcommit`tkv_gate`thotrod`tartifact`tnotes"
$map = @{}
Get-Content $p -Encoding UTF8 | Select-Object -Skip 1 | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_)) { return }
    $id = ($_ -split "`t")[0]
    $map[$id] = $_
}
@($h) + @($map.Values) | Set-Content $p -Encoding UTF8
Write-Host "Deduped to $($map.Count) models"