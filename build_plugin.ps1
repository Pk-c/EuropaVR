# Builds build\EuropaVR.dll, the UEVR C++ plugin.
#   .\build_plugin.ps1 -UevrSdk "C:\path\to\UEVR\include"
param(
    [string]$UevrSdk = "H:\UEVR\include"
)
$ErrorActionPreference = "Stop"

$root  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$build = Join-Path $root "build"
New-Item -ItemType Directory -Force -Path $build | Out-Null

$sdk = $UevrSdk
if (-not (Test-Path (Join-Path $sdk "uevr\Plugin.hpp"))) {
    throw "UEVR SDK not found in '$sdk'. The include\ folder ships with UEVR. Use -UevrSdk to point at it."
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$inst = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$vcvars = Join-Path $inst "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found in $inst" }

# /MT: the plugin is loaded into the game's process, so avoid any dependency on the
# redistributable VC runtime.
$cflags = "/nologo /std:c++20 /EHsc /O2 /MT /W3 /DNOMINMAX /DWIN32_LEAN_AND_MEAN /I`"$sdk`""
$lflags = "/DLL /OUT:build\EuropaVR.dll /IMPLIB:build\EuropaVR.lib"

$bat = Join-Path $env:TEMP "europavr_plugin_build.bat"
@"
@echo off
call "$vcvars" >nul 2>nul
if errorlevel 1 exit /b 1
cd /d "$root"
cl $cflags /Fobuild\plugin_ /Fdbuild\plugin_ plugin\EuropaVRPlugin.cpp /link $lflags
exit /b %errorlevel%
"@ | Out-File -FilePath $bat -Encoding ascii

& cmd.exe /c "`"$bat`""
$code = $LASTEXITCODE
Remove-Item $bat -ErrorAction SilentlyContinue

if ($code -ne 0) { throw "Plugin build failed (exit code $code)" }
Write-Host "`nOK -> $build\EuropaVR.dll" -ForegroundColor Green
