"""Dumps the FName table of a cooked UE4 .uasset.

The name table holds every component, variable, function and bone name a
Blueprint or Skeleton refers to, which is all we need to map the game's camera
rig and skeleton without a full asset decompiler.
"""
import struct
import sys
from pathlib import Path

PACKAGE_TAG = 0x9E2A83C1


class Reader:
    def __init__(self, data: bytes):
        self.d = data
        self.o = 0

    def i32(self) -> int:
        v = struct.unpack_from("<i", self.d, self.o)[0]
        self.o += 4
        return v

    def u32(self) -> int:
        v = struct.unpack_from("<I", self.d, self.o)[0]
        self.o += 4
        return v

    def skip(self, n: int) -> None:
        self.o += n

    def fstring(self) -> str:
        n = self.i32()
        if n == 0:
            return ""
        if n < 0:  # UTF-16, -n chars including the null terminator
            n = -n
            raw = self.d[self.o:self.o + n * 2]
            self.o += n * 2
            return raw.decode("utf-16-le", "replace").rstrip("\0")
        raw = self.d[self.o:self.o + n]
        self.o += n
        return raw.decode("latin-1", "replace").rstrip("\0")


def dump_names(path: Path):
    r = Reader(path.read_bytes())

    tag = r.u32()
    if tag != PACKAGE_TAG:
        raise ValueError(f"{path.name}: not a UE package (tag {tag:#x})")

    legacy = r.i32()          # -7 for UE4.27
    r.i32()                   # LegacyUE3Version
    ue4_version = r.i32()
    r.i32()                   # FileVersionLicenseeUE4

    if legacy <= -2:          # custom versions: count, then (FGuid, int32) each
        r.skip(r.i32() * 20)

    r.i32()                   # TotalHeaderSize
    r.fstring()               # FolderName
    r.u32()                   # PackageFlags

    name_count = r.i32()
    name_offset = r.i32()

    r.o = name_offset
    names = []
    # Cooked shipping packages have their version fields zeroed out, so a plain
    # ">= VER_UE4_NAME_HASHES_SERIALIZED" test would wrongly skip the two hash
    # words that are in fact present. Zero means "unversioned", i.e. modern.
    has_hashes = ue4_version == 0 or ue4_version >= 504
    for _ in range(name_count):
        names.append(r.fstring())
        if has_hashes:
            r.skip(4)
    return names


if __name__ == "__main__":
    keywords = [k.lower() for k in sys.argv[2:]]
    names = dump_names(Path(sys.argv[1]))
    print(f"# {Path(sys.argv[1]).name}: {len(names)} names")
    for n in names:
        if not keywords or any(k in n.lower() for k in keywords):
            print(n)
