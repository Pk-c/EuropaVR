# EuropaVR

A first-person VR mod for **[Europa](https://store.steampowered.com/app/1888930/Europa/)** (Novadust Entertainment), built on praydog's [UEVR](https://github.com/praydog/UEVR).

Europa is a third-person Unreal Engine 4.27 game. This mod turns it into a first-person VR experience: the camera sits at the character's head, the body faces wherever you look, and movement works like an FPS with snap turning.

> ⚠️ Work in progress. Playable, but not finished.

## What it does

- **First-person view** anchored to the character skeleton's `head` bone
- **No head bob** — the view rides the character capsule rather than the animated bone, with a low-pass filtered eye height
- **The body follows your gaze**, so the headset decides which way you walk
- **Snap turn** on the right stick, rotating both the view and the character
- **Strafing and backpedalling** without the character pivoting to face its velocity
- **Cutscenes left alone** — the mod hands the shot back as soon as the game frames something other than the player
- **Audio fix** — UE4 mutes the game when its window loses focus to SteamVR

## Installing (end users)

The mod is designed to be **copied into the game folder with no injector to run**. Launch the game normally from Steam and it goes to VR on its own.

A release will ship a ready-made archive. Until then, see Building below.

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

## Settings

`Binaries\Win64\EuropaVR\EuropaVR.ini` — loader: VR runtime, timings, audio fix, UEVR menu.

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

The mod builds on [UEVR](https://github.com/praydog/UEVR) (MIT). Releases will redistribute `UEVRBackend.dll`, `UEVRPluginNullifier.dll`, `openvr_api.dll` (BSD-3-Clause) and `openxr_loader.dll` (Apache-2.0) along with their licence notices.

No game content is included in this repository.
