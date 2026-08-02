# Third-party licence texts

Fetched from their authoritative sources, never reproduced from memory — that is
exactly how you end up shipping a licence that says something the original does
not.

| File | Covers | Source |
|---|---|---|
| `UEVR-LICENSE.txt` | UEVR as a whole | <https://github.com/praydog/UEVR/blob/master/LICENSE> |
| `OpenVR-BSD-3-Clause.txt` | `openvr_api.dll` | <https://github.com/ValveSoftware/openvr/blob/master/LICENSE> |
| `OpenXR-Apache-2.0.txt` | `openxr_loader.dll` | <https://github.com/KhronosGroup/OpenXR-SDK/blob/main/LICENSE> |

## Read UEVR-LICENSE.txt before assuming anything

It is three lines long and says **All rights reserved**. UEVR is not MIT.

The MIT licence that *is* part of UEVR governs only its `include/` directory —
the plugin SDK — and the file `include/LICENSE` states that it is "separate from
the license for the rest of the UEVR codebase". `package.ps1` copies that one
straight out of the UEVR install as `UEVR-SDK-LICENSE.txt`, because EuropaVR.dll
is compiled against those headers.

That distinction is why releases do not bundle `UEVRBackend.dll` or
`UEVRPluginNullifier.dll`. See `THIRD-PARTY.txt`.

The OpenVR and OpenXR texts only need to travel with a build that actually ships
those DLLs, which is `package.ps1 -IncludeUevr`. Apache-2.0 section 4 requires
handing recipients a copy of the licence, so that one is not optional when it
applies.
