#!/usr/bin/env pwsh
# Shared path resolution for Godzilla scripts (dot-source from scripts/ or scripts/benchmarks/).

function Get-GodzillaRepoRoot {
    param([string]$Override = "")
    if ($Override) { return (Resolve-Path -LiteralPath $Override).Path }
    if ($env:GODZILLA_ROOT) { return $env:GODZILLA_ROOT.TrimEnd('\', '/')
    }
    $here = $PSScriptRoot
    if (-not $here) {
        $here = Split-Path -Parent $MyInvocation.PSCommandPath
    }
    if ($here -match '[\\/]benchmarks$') {
        return (Resolve-Path -LiteralPath (Join-Path $here '..\..')).Path
    }
    if (Test-Path -LiteralPath (Join-Path $here 'CMakeLists.txt')) {
        return (Resolve-Path -LiteralPath $here).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $here '..')).Path
}

function Get-ModelsDir {
    param([string]$Override = "")
    if ($Override) { return $Override }
    if ($env:MODELS_DIR) { return $env:MODELS_DIR.TrimEnd('\', '/') }
    throw "MODELS_DIR is not set. See docs/LOCAL-SETUP.example.md."
}

function Get-TriCalibDir {
    param([string]$Override = "")
    if ($Override) { return $Override }
    if ($env:TRIATTENTION_CALIB_DIR) { return $env:TRIATTENTION_CALIB_DIR.TrimEnd('\', '/') }
    return Join-Path (Get-GodzillaRepoRoot) "calibrations"
}

function Get-BitNetRefRoot {
    if ($env:BITNET_REF_ROOT) { return $env:BITNET_REF_ROOT.TrimEnd('\', '/') }
    return $null
}

function Get-SomsRoot {
    if ($env:SOMS_ROOT) { return $env:SOMS_ROOT.TrimEnd('\', '/') }
    return $null
}

function Get-WslRepoPath {
    param([string]$WinPath = "")
    if (-not $WinPath) { $WinPath = Get-GodzillaRepoRoot }
    if ($env:WSL_GODZILLA_ROOT) { return $env:WSL_GODZILLA_ROOT.TrimEnd('/') }
    $wsl = wsl wslpath -u $WinPath 2>$null
    if ($wsl) { return $wsl.Trim() }
    throw "Cannot map repo path to WSL. Set WSL_GODZILLA_ROOT (e.g. /path/to/godzilla-llama.cpp)."
}

function Get-WdkRoot {
    if ($env:WDK_ROOT) { return $env:WDK_ROOT.TrimEnd('\', '/') }
    return $null
}
