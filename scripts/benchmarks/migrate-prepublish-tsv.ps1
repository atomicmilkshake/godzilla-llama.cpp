#!/usr/bin/env pwsh
. (Join-Path $PSScriptRoot "godzilla-env.ps1")
$SummaryPath = Join-Path $GodzillaLogDir "prepublish_sweep_summary.tsv"
Ensure-PrepublishSweepTsvSchema -Path $SummaryPath
$header = Get-PrepublishSweepTsvHeader
$rows = Get-Content $SummaryPath -Encoding UTF8 | Select-Object -Skip 1
$map = @{}
foreach ($row in $rows) {
    if ([string]::IsNullOrWhiteSpace($row)) { continue }
    $normalized = Convert-PrepublishSweepLegacyRow -Row $row
    $id = ($normalized -split "`t")[0]
    $map[$id] = $normalized
}
@($header) + @($map.Values) | Set-Content $SummaryPath -Encoding UTF8
Write-Host "Migrated $($map.Count) rows (deduped)"
