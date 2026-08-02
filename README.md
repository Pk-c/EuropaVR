# EuropaVR

A first-person VR mod for **[Europa](https://store.steampowered.com/app/1888930/Europa/)** (Novadust Entertainment), built on praydog's [UEVR](https://github.com/praydog/UEVR).

Europa is a third-person Unreal Engine 4.27 game. This mod turns it into a first-person VR experience: the camera sits at the character's head, the body faces wherever you look, and movement works like an FPS with snap turning.

> This is still a work in progress. the game is playable, but I plan to add more to make it as immersive as possible !

## What it does

- **First-person view** anchored to the character skeleton's `head` bone
- **No head bob** — the view rides the character capsule rather than the animated bone, with a low-pass filtered eye height
- **The body follows your gaze**, so the headset decides which way you walk
- **Snap turn** on the right stick, rotating both the view and the character
- **Strafing and backpedalling** without the character pivoting to face its velocity
- **Cutscenes left alone** — the mod hands the shot back as soon as the game frames something other than the player
- **Audio fix** — UE4 mutes the game when its window loses focus to SteamVR

## Installing

No injector to run, nothing to click. Launch the game normally from Steam and it goes to VR on its own.

**1. Get the archive.** Download `EuropaVR-vX.Y.Z.zip` from [Releases](https://github.com/Pk-c/EuropaVR/releases), and close the game if it is running.

**2. Extract it into your Europa folder.** In Steam: right click Europa → *Manage* → *Browse local files*. Copy the `Europa` folder from the archive on top of the one already there. If you did it right, this now exists:

```
...\steamapps\common\Europa\Europa\Binaries\Win64\dsound.dll
```

**3. Add UEVR's files.** Download `UEVR.zip` from [UEVR's releases](https://github.com/praydog/UEVR/releases) and copy these four files into `Europa\Binaries\Win64\EuropaVR\`:

```
UEVRBackend.dll   UEVRPluginNullifier.dll   openxr_loader.dll   openvr_api.dll
```

A `COPY-UEVR-FILES-HERE.txt` marks the spot; delete it once you are done. This step exists because UEVR is *All rights reserved* and is not ours to redistribute — see [Licences](#licences).

**4. Put your headset on and launch Europa from Steam.** It starts flat, then switches to VR by itself a few seconds after the window appears.

### Controls

| Input | Action |
|---|---|
| Left stick | Move, relative to where you are looking |
| Right stick | Snap turn |
| `Insert` or L3+R3 | UEVR menu (settings, camera offsets) |

Everything else keeps the game's own gamepad mapping.

### Uninstalling

Delete `Binaries\Win64\dsound.dll` and the `Binaries\Win64\EuropaVR\` folder. The game is then exactly as it was. Two harmless leftovers sit outside the game folder: `%APPDATA%\UnrealVRMod\Europa-Win64-Shipping\`, and the `[Audio]` / `[SystemSettings]` entries the mod adds to `%LOCALAPPDATA%\Europa\Saved\Config\WindowsNoEditor\Engine.ini`.

### If something goes wrong

The loader logs every step to `Binaries\Win64\EuropaVR\EuropaVR.log`, so it will say where things stopped.

- **Stays flat** — check the log, and that your VR runtime is running.
- **Crashes on launch** — UEVR is loading too early. Raise `PostWindowDelayMs` to `15000` in `EuropaVR.ini`. `Enabled=0` disables the mod without uninstalling it.
- **SteamVR shows the game in its desktop theatre and asks you to "Resume game"** — expected. Steam hands the game SteamVR's OpenXR runtime, SteamVR sees a flat app, and the mod only turns it into a VR app a few seconds later. Dismiss the prompt once and you are in. Lowering `PostWindowDelayMs` shortens the flat window. Setting `UseSystemOpenXrRuntime=1` removes the prompt entirely by using your own OpenXR runtime instead of SteamVR's — a real change of runtime, so only do it if that is what you want.

## Architecture

Three pieces, each where it works best:

| Piece | Responsibility |
|---|---|
| `src/` — `dsound.dll` proxy | Gets loaded by the game at startup, neutralises the engine's VR plugins, seeds the profile, then loads the VR runtime and UEVR |
| `plugin/` — UEVR C++ plugin | Everything rotational: view rotation, snap turn, HMD yaw, body orientation |
| `payload/profile/scripts/` — UEVR Lua script | View position, head hiding, spring arm settings |

**Why a `dsound.dll` proxy:** `UEVRBackend.dll` exports only `g_plugin_initialize_param`, so it cannot simply be renamed into a proxy DLL. `dsound.dll` is statically imported by the game, is not a KnownDLL, and has just 12 exports — the best candidate. `xinput1_3.dll` was ruled out because UEVR hooks XInput itself.

**Why a C++ plugin and not only Lua:** UEVR's Lua sandbox exposes no `io` library and no `K2_SetActorRotation`, and the rotation handed to the stereo view callback does not contain the headset orientation. From C++ the HMD pose is directly readable, so the world yaw can be derived instead of guessed.

## Building

Requirements: Visual Studio with the x64 C++ tools, and [UEVR](https://github.com/praydog/UEVR/releases) extracted somewhere — its `include/` folder is the plugin SDK.

```powershell
.\build.ps1                                      # -> build\dsound.dll   (the proxy)
.\build_plugin.ps1 -UevrSdk "C:\UEVR\include"    # -> build\EuropaVR.dll (the plugin)
.\deploy.ps1 -GameDir "C:\...\steamapps\common\Europa" -UevrDir "C:\UEVR"
```

To remove everything and return the game to its original state:

```powershell
.\deploy.ps1 -Uninstall
```

## Performance and image quality

Europa is tuned for flat screens: it renders at **65% resolution** and upscales with FSR. That is a sensible trade on a monitor and an expensive one in a headset, so the mod raises it back to 100% and turns FSR off. Stereo rendering at full resolution is well over double the pixels the game normally draws, so **expect to give some framerate back**.

Everything below is in `Binaries\Win64\EuropaVR\EuropaVR.ini`, applied to the game's `Engine.ini` at launch.

| Setting | Default | What it does |
|---|---|---|
| `ScreenPercentage` | `100` | Internal resolution, in percent. **The first dial to lower.** Try `85`, then `75`. The game's own default was `65`. |
| `DisableFSR` | `1` | Turns FSR off. If you drop `ScreenPercentage` a long way, setting this back to `0` lets FSR upscale again — softer, but cheaper than the resolution it buys back. |
| `AntiAliasing` | `-1` | `-1` leaves the game's choice (TAA). TAA is what causes ghosting in VR, but removing it makes the foliage shimmer, and this game is full of it. Try `1` (FXAA) or `0` (none) and pick your poison. |
| `FixVRRendering` | `1` | `0` leaves the game's rendering settings completely alone. |

Two more levers live outside that file:

- **UEVR menu → Resolution Scale** — scales the VR render target itself, independently of the game's own screen percentage. Adjustable live, in the headset.
- **UEVR menu → Rendering Method** — *Native Stereo* is the default and looks best. *Synchronized Sequential* and *AFR* trade image quality for speed and are worth trying if the framerate is far off.

If you are hunting frames, lower `ScreenPercentage` first: it is the single biggest cost, and the change is immediately visible.

## Settings

`Binaries\Win64\EuropaVR\EuropaVR.ini` — loader: VR runtime, timings, audio fix, rendering, UEVR menu.

`%APPDATA%\UnrealVRMod\Europa-Win64-Shipping\EuropaVR_plugin.ini` — plugin:

| Key | Effect |
|---|---|
| `YawSign` | `-1` or `1`. Flip it if the character turns the opposite way to your head. |
| `YawOffset` | Constant offset in degrees, if the body sits crooked. |
| `ForwardOffset` | Pushes the eye out of the body (cm). |
| `SnapAngle` | Snap turn step. |

The Lua script **hot-reloads** from the UEVR menu (`Insert` key), which is handy for tuning eye height without restarting.

## Tooling

`tools/uasset_names.py` dumps the FName table of a cooked UE4 `.uasset`. It is what identified the player pawn, the camera components and the head bone without any game source. It handles *unversioned* packages — cooked builds zero out the version fields, and the usual version check then wrongly skips the name hashes.

Extracting the `.pak` uses [repak](https://github.com/trumank/repak), which is not vendored here.

## Licences

Code in this repository: MIT (see `LICENSE`).

**UEVR itself is "All rights reserved"** — only its `include/` directory is MIT, and that directory says so explicitly. The plugin is built against those MIT headers, which is fine, but `UEVRBackend.dll` and `UEVRPluginNullifier.dll` are **not** redistributed by this project. Releases ship only our own files; users download UEVR themselves and copy four DLLs in, as `INSTALL.txt` explains.

See `THIRD-PARTY.txt` for the full breakdown.

No game content is included in this repository. Europa is the property of Novadust Entertainment.
