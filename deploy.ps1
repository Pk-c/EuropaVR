# Deploie (ou retire) EuropaVR dans le dossier du jeu.
#   .\deploy.ps1              -> installe
#   .\deploy.ps1 -Uninstall   -> desinstalle proprement
param(
    [string]$GameDir  = "H:\Steam\steamapps\common\Europa",
    [string]$UevrDir  = "H:\UEVR",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition

$binaries = Join-Path $GameDir "Europa\Binaries\Win64"
if (-not (Test-Path (Join-Path $binaries "Europa-Win64-Shipping.exe"))) {
    throw "Europa-Win64-Shipping.exe introuvable dans $binaries"
}

$proxy   = Join-Path $binaries "dsound.dll"
$payload = Join-Path $binaries "EuropaVR"

# Engine.ini du jeu : c'est la que vit le correctif audio (UE4 coupe le son quand
# la fenetre perd le focus au demarrage de SteamVR).
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

if ($Uninstall) {
    if (Test-Path $proxy)   { Remove-Item $proxy -Force;             Write-Host "Retire : dsound.dll" }
    if (Test-Path $payload) { Remove-Item $payload -Recurse -Force;  Write-Host "Retire : EuropaVR\" }
    Set-UnfocusedAudio -Path $engineIni -Remove
    Write-Host "Retire : UnfocusedVolumeMultiplier dans Engine.ini"
    Write-Host "Desinstalle. Le jeu est revenu a l'etat d'origine." -ForegroundColor Green
    return
}

$built = Join-Path $root "build\dsound.dll"
if (-not (Test-Path $built)) { throw "build\dsound.dll absent - lance d'abord .\build.ps1" }

# Garde-fou : ne jamais ecraser un vrai dsound.dll qui ne serait pas le notre.
if ((Test-Path $proxy) -and -not (Test-Path $payload)) {
    throw "Un dsound.dll etranger existe deja dans $binaries - a verifier manuellement."
}

New-Item -ItemType Directory -Force -Path $payload | Out-Null

$fromUevr = @("UEVRBackend.dll", "UEVRPluginNullifier.dll", "openxr_loader.dll", "openvr_api.dll")
foreach ($f in $fromUevr) {
    $src = Join-Path $UevrDir $f
    if (-not (Test-Path $src)) { throw "Fichier UEVR manquant : $src" }
    Copy-Item $src (Join-Path $payload $f) -Force
    Write-Host "  payload <- $f"
}

# Le profil UEVR complet part dans le dossier du jeu. C'est le chargeur qui le
# recopiera dans %APPDATA% au premier lancement, ce qui rend l'installation
# reellement autonome : l'utilisateur final n'a rien a placer a la main.
$profileSrc = Join-Path $root "payload\profile"
$profileDst = Join-Path $payload "profile"
Copy-Item $profileSrc $payload -Recurse -Force
Write-Host "  payload <- profile\ (config.txt, scripts\)"

# Le plugin C++ vit dans le sous-dossier plugins du profil, la ou UEVR le cherche.
$plugin = Join-Path $root "build\EuropaVR.dll"
if (Test-Path $plugin) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profileDst "plugins") | Out-Null
    Copy-Item $plugin (Join-Path $profileDst "plugins\EuropaVR.dll") -Force
    Write-Host "  payload <- profile\plugins\EuropaVR.dll"
} else {
    Write-Warning "build\EuropaVR.dll absent - lance .\build_plugin.ps1 (sans lui, pas de rotation du corps)"
}

# Ne pas ecraser un EuropaVR.ini deja ajuste par l'utilisateur.
$ini = Join-Path $payload "EuropaVR.ini"
if (-not (Test-Path $ini)) {
    Copy-Item (Join-Path $root "payload\EuropaVR.ini") $ini -Force
    Write-Host "  payload <- EuropaVR.ini"
} else {
    Write-Host "  payload    EuropaVR.ini (conserve)"
}

Copy-Item $built $proxy -Force
Write-Host "  Binaries\Win64 <- dsound.dll"

# Applique le correctif audio des maintenant, pour que meme le tout premier
# lancement ne coure pas contre la lecture de config par le moteur.
Set-UnfocusedAudio -Path $engineIni
Write-Host "  Engine.ini     <- [Audio] UnfocusedVolumeMultiplier=1.0"

Write-Host "`nInstalle dans $binaries" -ForegroundColor Green
Write-Host "Lance le jeu normalement (Steam). Log : $payload\EuropaVR.log"
