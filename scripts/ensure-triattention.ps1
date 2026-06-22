# Ensure a .triattention calibration file exists; generate via HF if missing.
param(
    [Parameter(Mandatory = $true)][string]$Gguf,
    [Parameter(Mandatory = $true)][string]$Output,
    [string]$HfModel = "",
    [int]$NTokens = 2048,
    [string]$Device = "cuda"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent

# Prefer J: for HF cache — C: often lacks space for 12B+ BF16 checkpoints
if (-not $env:HF_HOME) {
    $hfHome = "J:\LLM\huggingface-cache"
    $env:HF_HOME = $hfHome
    $env:HF_HUB_CACHE = Join-Path $hfHome "hub"
    $env:HF_DATASETS_CACHE = Join-Path $hfHome "datasets"
    if (-not (Test-Path -LiteralPath $env:HF_HUB_CACHE)) {
        New-Item -ItemType Directory -Force -Path $env:HF_HUB_CACHE | Out-Null
    }
    if (-not (Test-Path -LiteralPath $env:HF_DATASETS_CACHE)) {
        New-Item -ItemType Directory -Force -Path $env:HF_DATASETS_CACHE | Out-Null
    }
}

if (Test-Path -LiteralPath $Output) {
    Write-Host "TriAttention calibration present: $Output"
    exit 0
}

if (-not (Test-Path -LiteralPath $Gguf)) {
    throw "GGUF not found: $Gguf"
}

$ResolvePy = Join-Path $PSScriptRoot "resolve-triattention-hf.py"
$CalibratePy = "J:\LLM\TurboQuantExperimentation\scripts\calibrate-triattention.py"
$VenvPy = "J:\LLM\TurboQuantExperimentation\venv-calibrate-win312\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $VenvPy)) {
    $VenvPy = "J:\LLM\TurboQuantExperimentation\venv-calibrate\Scripts\python.exe"
}
if (-not (Test-Path -LiteralPath $VenvPy)) {
    throw "TriAttention calibration venv not found (venv-calibrate-win312 or venv-calibrate)"
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