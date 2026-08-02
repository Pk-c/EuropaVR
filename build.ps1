# Builds build\dsound.dll (the EuropaVR proxy) with the MSVC toolchain.
$ErrorActionPreference = "Stop"

$root  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$build = Join-Path $root "build"
New-Item -ItemType Directory -Force -Path $build | Out-Null

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found - Visual Studio is not installed." }

$inst = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $inst) { throw "No Visual Studio install with the x64 C++ tools." }

$vcvars = Join-Path $inst "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found in $inst" }

$sources = @(
    "src\dllmain.cpp"
    "src\common.cpp"
    "src\bootstrap.cpp"
    "src\proxy_dsound.cpp"
) -join " "

$cflags = "/nologo /std:c++20 /EHsc /O2 /MT /W4 /permissive- /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX"
# /IGNORE:4222 - the real dsound.dll does give ordinals to the two COM entry
# points, and we mirror its table exactly, so the convention warning is expected.
$lflags = "/DLL /DEF:EuropaVR.def /IGNORE:4222 /OUT:build\dsound.dll /IMPLIB:build\dsound.lib shell32.lib ole32.lib user32.lib"

$bat = Join-Path $env:TEMP "europavr_build.bat"
@"
@echo off
call "$vcvars" >nul 2>nul
if errorlevel 1 exit /b 1
cd /d "$root"
cl $cflags /Fobuild\ /Fdbuild\ $sources /link $lflags
exit /b %errorlevel%
"@ | Out-File -FilePath $bat -Encoding ascii

& cmd.exe /c "`"$bat`""
$code = $LASTEXITCODE
Remove-Item $bat -ErrorAction SilentlyContinue

if ($code -ne 0) { throw "Build failed (exit code $code)" }
Write-Host "`nOK -> $build\dsound.dll" -ForegroundColor Green
