# Assemble une archive de release prete a decompresser dans le dossier du jeu.
#
# L'archive reproduit l'arborescence du jeu : l'utilisateur extrait le contenu dans
# steamapps\common\Europa\ et tout tombe au bon endroit, sans rien a placer a la main.
param(
    [string]$Version = "0.1.0",
    [string]$UevrDir = "H:\UEVR",
    [string]$OutDir  = "dist"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition

$proxy  = Join-Path $root "build\dsound.dll"
$plugin = Join-Path $root "build\EuropaVR.dll"
foreach ($f in @($proxy, $plugin)) {
    if (-not (Test-Path $f)) { throw "$f absent - lance .\build.ps1 et .\build_plugin.ps1 d'abord." }
}

$name    = "EuropaVR-v$Version"
$dist    = Join-Path $root $OutDir
$stage   = Join-Path $dist $name
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# --- arborescence miroir du jeu ------------------------------------------------
$win64   = Join-Path $stage "Europa\Binaries\Win64"
$payload = Join-Path $win64 "EuropaVR"
New-Item -ItemType Directory -Force -Path (Join-Path $payload "profile\plugins") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $payload "profile\scripts") | Out-Null

Copy-Item $proxy (Join-Path $win64 "dsound.dll") -Force

$redist = @("UEVRBackend.dll", "UEVRPluginNullifier.dll", "openxr_loader.dll", "openvr_api.dll")
foreach ($f in $redist) {
    $src = Join-Path $UevrDir $f
    if (-not (Test-Path $src)) { throw "Fichier UEVR manquant : $src" }
    Copy-Item $src (Join-Path $payload $f) -Force
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

# Ce qu'on peut recuperer localement, verbatim.
$uevrDisclaimer = Join-Path $UevrDir "DISCLAIMER.txt"
if (Test-Path $uevrDisclaimer) { Copy-Item $uevrDisclaimer (Join-Path $licDir "UEVR-DISCLAIMER.txt") -Force }
$uevrSdkLicense = Join-Path $UevrDir "include\LICENSE"
if (Test-Path $uevrSdkLicense) { Copy-Item $uevrSdkLicense (Join-Path $licDir "UEVR-SDK-LICENSE.txt") -Force }

# Textes de licence deposes par le mainteneur (voir licenses\README.md du depot).
$repoLicenses = Join-Path $root "licenses"
$missing = @()
foreach ($item in @(
    @{ File = "OpenXR-Apache-2.0.txt"; For = "openxr_loader.dll" },
    @{ File = "OpenVR-BSD-3-Clause.txt"; For = "openvr_api.dll" },
    @{ File = "UEVR-MIT.txt"; For = "UEVRBackend.dll / UEVRPluginNullifier.dll" }
)) {
    $src = Join-Path $repoLicenses $item.File
    if (Test-Path $src) { Copy-Item $src $licDir -Force } else { $missing += "$($item.File)  ($($item.For))" }
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
    Write-Warning "Textes de licence absents de licenses\ :"
    $missing | ForEach-Object { Write-Warning "   $_" }
    Write-Warning "Apache-2.0 exige de fournir une copie de la licence avec le binaire redistribue."
    Write-Warning "Voir licenses\README.md."
}
