#!/usr/bin/env pwsh
# Download BitNet-b1.58-2B-4T I2_S GGUF from Hugging Face into MODELS_DIR
param(
    [string]$DestDir = "",
    [string]$RepoId = "microsoft/bitnet-b1.58-2B-4T-gguf",
    [string]$Filename = "ggml-model-i2_s.gguf"
)

. (Join-Path $PSScriptRoot "godzilla-paths.ps1")

$ErrorActionPreference = "Stop"
if (-not $DestDir) {
    $DestDir = Join-Path (Get-ModelsDir) "bitnet-b1.58-2B-4T"
}
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

python -c @"
from huggingface_hub import hf_hub_download
import os
path = hf_hub_download('$RepoId', '$Filename', local_dir=r'$DestDir')
print('Downloaded:', path)
print('Size GB:', round(os.path.getsize(path)/1e9, 3))
"@

Write-Host "Model ready at: $DestDir\$Filename"
