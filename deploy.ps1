# Installs (or removes) EuropaVR in the game folder, for development.
#   .\deploy.ps1              -> install
#   .\deploy.ps1 -Uninstall   -> clean removal
#
# End users get the release archive instead; see package.ps1. This script also copies
# UEVR's binaries out of a local install, which a release must not do.
param(
    [string]$GameDir  = "H:\Steam\steamapps\common\Europa",
    [string]$UevrDir  = "H:\UEVR",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition

$binaries = Join-Path $GameDir "Europa\Binaries\Win64"
if (-not (Test-Path (Join-Path $binaries "Europa-Win64-Shipping.exe"))) {
    throw "Europa-Win64-Shipping.exe not found in $binaries"
}

$proxy   = Join-Path $binaries "dsound.dll"
$payload = Join-Path $binaries "EuropaVR"

# The game's Engine.ini: where the audio fix lives, since UE4 mutes the game when its
# window loses focus as SteamVR starts.
$engineIni = Join-Path $env:LOCALAPPDATA "Europa\Saved\Config\WindowsNoEditor\Engine.ini"

function Set-UnfocusedAudio {
    param([string]$Path, [switch]$Remove)

    if (-not (Test-Path $Path)) {
        if ($Remove) { return }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        Set-Content -Path $Path -Value "" -Encoding utf8
    }

    $lines = @(Get-Content -Path $Path)
    $out = New-Object System.Collections.Generic.List[string]
    $inAudio = $false
    $done = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            if ($inAudio -and -not $Remove -and -not $done) {
                $out.Add("UnfocusedVolumeMultiplier=1.0"); $done = $true
            }
            $inAudio = ($matches[1] -eq "Audio")
            $out.Add($line)
            continue
        }
        if ($inAudio -and $line -match '^\s*UnfocusedVolumeMultiplier\s*=') {
            if (-not $Remove) { $out.Add("UnfocusedVolumeMultiplier=1.0"); $done = $true }
            continue
        }
        $out.Add($line)
    }

    if (-not $Remove -and -not $done) {
        if ($inAudio) {
            $out.Add("UnfocusedVolumeMultiplier=1.0")
        } else {
            $out.Add(""); $out.Add("[Audio]"); $out.Add("UnfocusedVolumeMultiplier=1.0")
        }
    }

    Set-Content -Path $Path -Value $out -Encoding utf8
}

# Drops whole sections from an ini. The loader writes [Audio] and [SystemSettings]
# at runtime, and an uninstall that only removed one key left the rendering overrides
# silently in force - which also quietly invalidates any clean-install test.
function Remove-IniSections {
    param([string]$Path, [string[]]$Sections)

    if (-not (Test-Path $Path)) { return }

    $out = New-Object System.Collections.Generic.List[string]
    $section = ""
    foreach ($line in @(Get-Content -Path $Path)) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $section = $matches[1] }
        if ($Sections -contains $section) { continue }
        $out.Add($line)
    }
    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq "") { $out.RemoveAt($out.Count - 1) }

    Set-Content -Path $Path -Value $out -Encoding utf8
}

if ($Uninstall) {
    if (Test-Path $proxy)   { Remove-Item $proxy -Force;            Write-Host "Removed: dsound.dll" }
    if (Test-Path $payload) { Remove-Item $payload -Recurse -Force; Write-Host "Removed: EuropaVR folder" }
    Remove-IniSections -Path $engineIni -Sections @("Audio", "SystemSettings")
    Write-Host "Removed: [Audio] and [SystemSettings] from Engine.ini"
    Write-Host "Uninstalled. The game is back to its original state." -ForegroundColor Green
    return
}

$built = Join-Path $root "build\dsound.dll"
if (-not (Test-Path $built)) { throw "build\dsound.dll missing - run .\build.ps1 first" }

# Guard rail: never overwrite a real dsound.dll that is not ours.
if ((Test-Path $proxy) -and -not (Test-Path $payload)) {
    throw "A foreign dsound.dll already exists in $binaries - check it by hand."
}

New-Item -ItemType Directory -Force -Path $payload | Out-Null

$fromUevr = @("UEVRBackend.dll", "UEVRPluginNullifier.dll", "openxr_loader.dll", "openvr_api.dll")
foreach ($f in $fromUevr) {
    $src = Join-Path $UevrDir $f
    if (-not (Test-Path $src)) { throw "Missing UEVR file: $src" }
    Copy-Item $src (Join-Path $payload $f) -Force
    Write-Host "  payload <- $f"
}

# The whole UEVR profile goes into the game folder. The loader copies it into %APPDATA%
# on first launch, which is what makes the install self-contained: the end user places
# nothing by hand.
$profileSrc = Join-Path $root "payload\profile"
$profileDst = Join-Path $payload "profile"
Copy-Item $profileSrc $payload -Recurse -Force
Write-Host "  payload <- profile\ (config.txt, scripts\)"

# The C++ plugin lives in the profile's plugins subfolder, where UEVR looks for it.
$plugin = Join-Path $root "build\EuropaVR.dll"
if (Test-Path $plugin) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profileDst "plugins") | Out-Null
    Copy-Item $plugin (Join-Path $profileDst "plugins\EuropaVR.dll") -Force
    Write-Host "  payload <- profile\plugins\EuropaVR.dll"
} else {
    Write-Warning "build\EuropaVR.dll missing - run .\build_plugin.ps1 (without it, the body will not turn)"
}

# Do not overwrite an EuropaVR.ini the user has already tuned.
$ini = Join-Path $payload "EuropaVR.ini"
if (-not (Test-Path $ini)) {
    Copy-Item (Join-Path $root "payload\EuropaVR.ini") $ini -Force
    Write-Host "  payload <- EuropaVR.ini"
} else {
    Write-Host "  payload    EuropaVR.ini (kept)"
}

Copy-Item $built $proxy -Force
Write-Host "  Binaries\Win64 <- dsound.dll"

# Apply the audio fix now, so even the very first launch does not race the engine
# reading its own config.
Set-UnfocusedAudio -Path $engineIni
Write-Host "  Engine.ini     <- [Audio] UnfocusedVolumeMultiplier=1.0"

Write-Host "`nInstalled into $binaries" -ForegroundColor Green
Write-Host "Launch the game normally from Steam. Log: $payload\EuropaVR.log"
