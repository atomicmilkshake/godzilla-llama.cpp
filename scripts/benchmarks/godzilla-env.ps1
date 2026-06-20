#!/usr/bin/env pwsh
# Shared Godzilla benchmark environment (dot-source from runners).
$script:GodzillaRepoRoot = "J:\LLM\godzilla-llama.cpp"
$script:SomsRoot = "J:\LLM\soms"
$script:GodzillaLogDir = Join-Path $GodzillaRepoRoot "logs\benchmarks"
$env:TURBO_INNERQ = "1"

function Get-GodzillaBinDir {
    Join-Path $GodzillaRepoRoot "build\bin"
}