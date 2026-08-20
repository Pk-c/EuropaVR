# EuropaVR

<img width="1774" height="887" alt="8535d43f-6645-4eec-968e-e37c6f87b50b" src="https://github.com/user-attachments/assets/caba7028-632a-4ef1-ac63-2a78b31540a1" />

A first-person VR mod for **[Europa](https://store.steampowered.com/app/2214880/Europa/)** (Novadust Entertainment), built on praydog's [UEVR](https://github.com/praydog/UEVR).

Europa is a third-person game. This mod turns it into a first-person VR experience: the camera sits at the character's head, the body faces wherever you look, and movement works like an FPS with snap & smooth turning.

If you like my work you can follow me on Patreon ( free membership ), I try to make like native mode for beautiful games!

https://patreon.com/ChromaticMod

<a href="https://patreon.com/ChromaticMod">
  <img width="200" height="105" alt="imakevrmodforgames-preview" src="https://github.com/user-attachments/assets/0517352b-e120-47bc-b062-b85fc333f814" />
</a>

OR

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/A0Y524C5N8)

## What it does

- **First-person 6DOF view** anchored to the character skeleton's `head` bone,  direction of movement is based on headset, controls are adapted for First person VR
- **Room scale movement with collisions**, you can move physically the character will follow, collision will prevent your camera to go inside walls
- **UI fix** the UI should be adapted for VR and readable
- **Graphic enhancement** — render scale set at 100% ( original game is 65% ), can be customized to fit your hardware

Youtube Demo :
[![Demo](https://img.youtube.com/vi/xH1kFPG1oWo/maxresdefault.jpg)](https://youtu.be/xH1kFPG1oWo)

## Installing

No injector to run, nothing to click. Launch the game normally from Steam and it goes to VR on its own.

**1. Get the archive.** Download `EuropaVR-v0.2.0.zip` from [Releases](https://github.com/Pk-c/EuropaVR/releases), and close the game if it is running.

**2. Extract it into your Europa folder.** In Steam: right click Europa → *Manage* → *Browse local files*. Copy the `Europa` folder from the archive on top of the one already there. If you did it right, this now exists:

```
...\steamapps\common\Europa\Europa\Binaries\Win64\dsound.dll
```

**3. Put your headset on and launch Europa from Steam.** It starts flat, then switches to VR by itself a few seconds after the window appears.

*If you are on linux you may need to add "WINEDLLOVERRIDES="dsound=n,b" %command%" as a launch option

### Controls

| Input | Action |
|---|---|
| Left stick | Move, relative to where you are looking |
| Right stick | Turn (snap by default) |
| Right stick click | Pause menu |
| `Insert` or L3+R3 | UEVR menu (settings, camera offsets) |

Everything else keeps the game's own gamepad mapping.

### Uninstalling

Delete `Binaries\Win64\dsound.dll` and the `Binaries\Win64\EuropaVR\` folder, and the mod is gone.

One leftover is worth cleaning up though. The mod adds `[Audio]` and `[SystemSettings]` sections to `%LOCALAPPDATA%\Europa\Saved\Config\WindowsNoEditor\Engine.ini`, and `[SystemSettings]` **keeps applying to the flat game** — it holds `r.ScreenPercentage=100`, so the game would run at full resolution instead of the 65% it ships with, and feel heavier than before you installed anything. Delete both sections to put it back as it was.

`%APPDATA%\UnrealVRMod\Europa-Win64-Shipping\` is inert without the mod and can be left alone.

## Settings

Everything is in one file: `Binaries\Win64\EuropaVR\EuropaVR.ini`.

Its top half is read once at startup — VR runtime, timings, audio fix, rendering. Its bottom half is **re-read about once a second**, so those apply while the game is running:

| Key | Effect |
|---|---|
| `YawSign` | `-1` or `1`. Flip it if the character turns the opposite way to your head. |
| `YawOffset` | Constant offset in degrees, if the body sits crooked. |
| `ForwardOffset` / `UpOffset` | Push the eye out of the body (cm). These add to UEVR's own camera offsets. |
| `TurnMode` | `0` snap, `1` smooth. `SnapAngle` and `SmoothTurnSpeed` go with them. |
| `PauseButton` | `0` off, `1` left menu button, `2` left stick click, `3` right stick click. |
| `BookDistance` | How far the in-game book sits from your face. The game's own value is 145, which is far too close in first person. |
| `ScreenPercentage` | `100` | Internal resolution, in percent. **The first dial to lower.** Try `85`, then `75`. The game's own default was `65`. |
| `FSR` | `0` | Off, because at 100% render scale there is nothing to upscale. Turn it back on if you drop `ScreenPercentage` a long way and want the sharpness back. |
| `AntiAliasing` | `-1` | `-1` leaves the game's choice (TAA). TAA is what causes ghosting in VR, but removing it makes the foliage shimmer, and this game is full of it. Try `1` (FXAA) or `0` (none) and pick your poison. |
| `FixVRRendering` | `1` | `0` leaves the game's rendering settings completely alone. |

The Lua script also **hot-reloads** from the UEVR menu (`Insert` key), for the things it still owns — eye height smoothing and how much of the character is drawn.

Two more levers live outside that file:

- **UEVR menu → Resolution Scale** — scales the VR render target itself, independently of the game's own screen percentage. Adjustable live, in the headset.
- **UEVR menu → Rendering Method** — *Native Stereo* is the default and looks best. *Synchronized Sequential* and *AFR* trade image quality for speed and are worth trying if the framerate is far off.

Europa is tuned for flat screens: it renders at **65% resolution** and upscales with FSR. That is a sensible trade on a monitor and an expensive one in a headset, so the mod raises it back to 100% and turns FSR off. Stereo rendering at full resolution is well over double the pixels the game normally draws, so **expect to give some framerate back**.

If you are hunting frames, lower `ScreenPercentage` first: it is the single biggest cost, and the change is immediately visible.

### Known Issues

-If you ever happen to re-spawn below the ground, open the UEVR menu with R3+L3 and then press Right trigger and Y to reset.

-Sometimes the book will appear at awkward place, most likely because the dev patched those place in 3rd person.

-SteamVR shows the game in its desktop theatre and asks you to "Resume game" — expected. Steam hands the game SteamVR's OpenXR runtime, SteamVR sees a flat app, and the mod only turns it into a VR app a few seconds later. 

### If something goes wrong

The loader logs every step to `Binaries\Win64\EuropaVR\EuropaVR.log`, so it will say where things stopped.

- **Stays flat** — check the log, and that your VR runtime is running.
- **Crashes on launch** — UEVR is loading too early. Raise `PostWindowDelayMs` to `15000` in `EuropaVR.ini`. `Enabled=0` disables the mod without uninstalling it.

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

## Tooling

`tools/uasset_names.py` dumps the FName table of a cooked UE4 `.uasset`. It is what identified the player pawn, the camera components and the head bone without any game source. It handles *unversioned* packages — cooked builds zero out the version fields, and the usual version check then wrongly skips the name hashes.

Extracting the `.pak` uses [repak](https://github.com/trumank/repak), which is not vendored here.

## Licences

Code in this repository: MIT (see `LICENSE`).

See `THIRD-PARTY.txt` for the full breakdown.

No game content is included in this repository. Europa is the property of Novadust Entertainment.
