# Tooling

Helpers used to reverse the game well enough to place the camera. Neither is needed to
build or run the mod.

## `uasset_names.py`

Dumps the FName table of a cooked UE4 `.uasset`. The name table holds every component,
variable, function and bone name a Blueprint or Skeleton refers to, which is enough to
map a game's rig without an asset decompiler.

```
python tools/uasset_names.py <file.uasset> [keyword ...]
```

Cooked shipping packages have their version fields zeroed out. The usual
`>= VER_UE4_NAME_HASHES_SERIALIZED` check then reads as false and the two hash words
after each name get skipped, which desynchronises the whole table — the script treats
version `0` as "unversioned, therefore modern" instead.

## `repak`

Not vendored. Grab a build from [trumank/repak](https://github.com/trumank/repak/releases)
and drop `repak.exe` here; `.gitignore` already excludes it.

Europa's pak is unencrypted and uncompressed (footer v11, empty compression method
table), so listing and extraction are straightforward:

```
tools\repak.exe info  "...\Europa\Content\Paks\Europa-WindowsNoEditor.pak"
tools\repak.exe list  "...\Europa-WindowsNoEditor.pak"
tools\repak.exe unpack "...\Europa-WindowsNoEditor.pak" -o extracted -i "Europa/Config"
```

Anything extracted belongs to Novadust Entertainment. `extracted/` is git-ignored and
must never be published.
