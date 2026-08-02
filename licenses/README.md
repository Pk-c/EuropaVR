# Third-party licence texts

`package.ps1` copies whatever it finds here into the release archive, and warns
about anything missing. These files are **not** vendored automatically, because
reproducing a licence text from memory is exactly how you ship a wrong one.

Fetch each from its authoritative source and save it under the expected name:

| File | Licence | Fetch from |
|---|---|---|
| `UEVR-MIT.txt` | MIT | <https://github.com/praydog/UEVR/blob/master/LICENSE> |
| `OpenVR-BSD-3-Clause.txt` | BSD-3-Clause | <https://github.com/ValveSoftware/openvr/blob/master/LICENSE> |
| `OpenXR-Apache-2.0.txt` | Apache-2.0 | <https://github.com/KhronosGroup/OpenXR-SDK/blob/main/LICENSE> |

Apache-2.0 section 4 requires giving recipients a copy of the licence with the
redistributed binary, so `OpenXR-Apache-2.0.txt` is the one that genuinely must
be present before publishing a release.

`UEVR-DISCLAIMER.txt` and `UEVR-SDK-LICENSE.txt` are picked up straight from the
UEVR install directory by `package.ps1`; nothing to do for those.
