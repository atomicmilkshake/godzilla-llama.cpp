#!/usr/bin/env pwsh
# Download BitNet-b1.58-2B-4T I2_S GGUF from Hugging Face into J:\MOODLES
param(
    [string]$DestDir = "J:\MOODLES\bitnet-b1.58-2B-4T",
    [string]$RepoId = "microsoft/bitnet-b1.58-2B-4T-gguf",
    [string]$Filename = "ggml-model-i2_s.gguf"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

python -c @"
from huggingface_hub import hf_hub_download
import os
path = hf_hub_download('$RepoId', '$Filename', local_dir=r'$DestDir')
print('Downloaded:', path)
print('Size GB:', round(os.path.getsize(path)/1e9, 3))
"@

Write-Host "Model ready at: $DestDir\$Filename"
