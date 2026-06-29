#!/usr/bin/env pwsh
. (Join-Path $PSScriptRoot "godzilla-env.ps1")
$p = Join-Path $GodzillaLogDir "prepublish_sweep_summary.tsv"
$h = Get-PrepublishSweepTsvHeader
Ensure-PrepublishSweepTsvSchema -Path $p
$map = @{}
Get-Content $p -Encoding UTF8 | Select-Object -Skip 1 | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_)) { return }
    $normalized = Convert-PrepublishSweepLegacyRow -Row $_
    $id = ($normalized -split "`t")[0]
    $map[$id] = $normalized
}
@($h) + @($map.Values) | Set-Content $p -Encoding UTF8
Write-Host "Deduped to $($map.Count) models"
