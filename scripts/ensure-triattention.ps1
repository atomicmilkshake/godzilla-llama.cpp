# Ensure a .triattention calibration file exists; generate via HF if missing.
param(
    [Parameter(Mandatory = $true)][string]$Gguf,
    [Parameter(Mandatory = $true)][string]$Output,
    [string]$HfModel = "",
    [int]$NTokens = 2048,
    [string]$Device = "cuda"
)

. (Join-Path $PSScriptRoot "godzilla-paths.ps1")

$ErrorActionPreference = "Stop"
$RepoRoot = Get-GodzillaRepoRoot

if (-not $env:HF_HOME -and $env:HF_CACHE_DIR) {
    $env:HF_HOME = $env:HF_CACHE_DIR
    $env:HF_HUB_CACHE = Join-Path $env:HF_HOME "hub"
    $env:HF_DATASETS_CACHE = Join-Path $env:HF_HOME "datasets"
}

if (Test-Path -LiteralPath $Output) {
    Write-Host "TriAttention calibration present: $Output"
    exit 0
}

if (-not (Test-Path -LiteralPath $Gguf)) {
    throw "GGUF not found: $Gguf"
}

$ResolvePy = Join-Path $PSScriptRoot "resolve-triattention-hf.py"
$CalibratePy = $env:TRIATTENTION_CALIBRATE_PY
$VenvPy = $env:TRIATTENTION_PYTHON
if (-not $CalibratePy) {
    throw "TRIATTENTION_CALIBRATE_PY not set. See docs/LOCAL-SETUP.example.md"
}
if (-not $VenvPy) {
    throw "TRIATTENTION_PYTHON not set. See docs/LOCAL-SETUP.example.md"
}
if (-not (Test-Path -LiteralPath $VenvPy)) {
    throw "TRIATTENTION_PYTHON not found: $VenvPy"
}
if (-not (Test-Path -LiteralPath $CalibratePy)) {
    throw "Missing calibrator: $CalibratePy"
}

if ([string]::IsNullOrWhiteSpace($HfModel)) {
    $HfModel = & $VenvPy $ResolvePy $Gguf
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($HfModel)) {
        throw "Failed to resolve HuggingFace model for $Gguf"
    }
}

$outDir = Split-Path -Parent $Output
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

Write-Host "TriAttention missing; calibrating $HfModel -> $Output (device=$Device, n=$NTokens)" -ForegroundColor Yellow

$calArgs = @(
    $CalibratePy,
    "--model", $HfModel,
    "--output", $Output,
    "--n-tokens", "$NTokens",
    "--device", $Device
)

& $VenvPy @calArgs
if ($LASTEXITCODE -ne 0) {
    if ($Device -eq "cuda") {
        Write-Host "CUDA calibration failed; retrying on CPU with n-tokens=512" -ForegroundColor Yellow
        & $VenvPy @($CalibratePy, "--model", $HfModel, "--output", $Output, "--n-tokens", "512", "--device", "cpu")
    }
}
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Output)) {
    throw "TriAttention calibration failed for $HfModel (output=$Output)"
}

Write-Host "TriAttention calibration written: $Output" -ForegroundColor Green
