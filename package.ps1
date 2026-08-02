# Builds a release archive, laid out so that extracting it into the game folder is the
# whole install.
#
# UEVR's own binaries are NOT bundled. UEVR is "All rights reserved" (only its include/
# directory is MIT), so redistributing UEVRBackend.dll or UEVRPluginNullifier.dll is not
# ours to do. Users fetch UEVR themselves; INSTALL.txt tells them which files to copy.
# -IncludeUevr exists for the day permission is granted, and for local test builds.
param(
    [string]$Version = "0.1.0",
    [string]$UevrDir = "H:\UEVR",
    [string]$OutDir  = "dist",
    [switch]$IncludeUevr
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition

$proxy  = Join-Path $root "build\dsound.dll"
$plugin = Join-Path $root "build\EuropaVR.dll"
foreach ($f in @($proxy, $plugin)) {
    if (-not (Test-Path $f)) { throw "$f missing - run .\build.ps1 and .\build_plugin.ps1 first." }
}

$name    = "EuropaVR-v$Version"
$dist    = Join-Path $root $OutDir
$stage   = Join-Path $dist $name
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# --- mirror of the game's folder layout ----------------------------------------
$win64   = Join-Path $stage "Europa\Binaries\Win64"
$payload = Join-Path $win64 "EuropaVR"
New-Item -ItemType Directory -Force -Path (Join-Path $payload "profile\plugins") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $payload "profile\scripts") | Out-Null

Copy-Item $proxy (Join-Path $win64 "dsound.dll") -Force

$redist = @("UEVRBackend.dll", "UEVRPluginNullifier.dll", "openxr_loader.dll", "openvr_api.dll")

if ($IncludeUevr) {
    foreach ($f in $redist) {
        $src = Join-Path $UevrDir $f
        if (-not (Test-Path $src)) { throw "Missing UEVR file: $src" }
        Copy-Item $src (Join-Path $payload $f) -Force
    }
    Write-Warning "UEVR binaries bundled. Do not publish this archive without permission from praydog."
} else {
    # A placeholder in the exact folder the files belong in beats an instruction
    # buried in a readme.
    @"
Copy these four files from your UEVR download into this folder:

    UEVRBackend.dll
    UEVRPluginNullifier.dll
    openxr_loader.dll
    openvr_api.dll

Get UEVR from https://github.com/praydog/UEVR/releases (the "UEVR.zip" asset).

They are not bundled because UEVR is "All rights reserved" and is not ours to
redistribute. Nothing else is needed; delete this file once you are done.
"@ | Out-File -FilePath (Join-Path $payload "COPY-UEVR-FILES-HERE.txt") -Encoding ascii
}

Copy-Item (Join-Path $root "payload\EuropaVR.ini")                                  (Join-Path $payload "EuropaVR.ini") -Force
Copy-Item (Join-Path $root "payload\profile\config.txt")                            (Join-Path $payload "profile\config.txt") -Force
Copy-Item (Join-Path $root "payload\profile\EuropaVR_plugin.ini")                   (Join-Path $payload "profile\EuropaVR_plugin.ini") -Force
Copy-Item (Join-Path $root "payload\profile\scripts\europavr_firstperson.lua")      (Join-Path $payload "profile\scripts\") -Force
Copy-Item $plugin                                                                   (Join-Path $payload "profile\plugins\EuropaVR.dll") -Force

# --- licences ------------------------------------------------------------------
Copy-Item (Join-Path $root "LICENSE") (Join-Path $stage "LICENSE") -Force

$licDir = Join-Path $stage "licenses"
New-Item -ItemType Directory -Force -Path $licDir | Out-Null

# The plugin is built against UEVR's include/ directory, which is MIT and separate
# from the rest of UEVR, so that notice belongs in every build whether or not any
# UEVR binary ships.
$uevrSdkLicense = Join-Path $UevrDir "include\LICENSE"
if (Test-Path $uevrSdkLicense) { Copy-Item $uevrSdkLicense (Join-Path $licDir "UEVR-SDK-LICENSE.txt") -Force }

$missing = @()
if ($IncludeUevr) {
    $uevrDisclaimer = Join-Path $UevrDir "DISCLAIMER.txt"
    if (Test-Path $uevrDisclaimer) { Copy-Item $uevrDisclaimer (Join-Path $licDir "UEVR-DISCLAIMER.txt") -Force }

    $repoLicenses = Join-Path $root "licenses"
    foreach ($item in @(
        @{ File = "OpenXR-Apache-2.0.txt";   For = "openxr_loader.dll" },
        @{ File = "OpenVR-BSD-3-Clause.txt"; For = "openvr_api.dll" }
    )) {
        $src = Join-Path $repoLicenses $item.File
        if (Test-Path $src) { Copy-Item $src $licDir -Force } else { $missing += "$($item.File)  ($($item.For))" }
    }
}

Copy-Item (Join-Path $root "THIRD-PARTY.txt") (Join-Path $stage "THIRD-PARTY.txt") -Force
Copy-Item (Join-Path $root "INSTALL.txt")     (Join-Path $stage "INSTALL.txt") -Force

# --- archive -------------------------------------------------------------------
$zip = Join-Path $dist "$name.zip"
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Optimal

Write-Host ""
Write-Host "OK -> $zip" -ForegroundColor Green
Get-ChildItem -Recurse -File $stage | ForEach-Object { "   " + $_.FullName.Replace("$stage\","") }

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Warning "Missing licence texts in licenses\:"
    $missing | ForEach-Object { Write-Warning "   $_" }
    Write-Warning "Apache-2.0 requires shipping a copy of the licence with the redistributed binary."
    Write-Warning "See licenses\README.md."
}
