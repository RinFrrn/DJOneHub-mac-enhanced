#!/usr/bin/env python3
"""Check the static ARM sender's load segments without cross-binutils."""
from pathlib import Path
import struct
import sys

data = Path(sys.argv[1]).read_bytes()
if len(data) < 52 or data[:7] != b"\x7fELF\x01\x01\x01":
    raise SystemExit("expected ELF32 little-endian executable")
kind, machine = struct.unpack_from("<HH", data, 16)
phoff = struct.unpack_from("<I", data, 28)[0]
phsize, phnum = struct.unpack_from("<HH", data, 42)
flags = struct.unpack_from("<I", data, 36)[0]
if kind != 2 or machine != 40 or flags & 0x400 or phsize != 32:
    raise SystemExit("expected ARM soft-float ET_EXEC")
bss = 0
loads = 0
for n in range(phnum):
    ptype, offset, _, _, filesz, memsz, perms, _ = struct.unpack_from("<8I", data, phoff + n * phsize)
    if ptype in (2, 3):
        raise SystemExit("sender must be static (no interpreter or dynamic section)")
    if ptype == 1:
        if memsz < filesz or offset + filesz > len(data) or perms & 3 == 3:
            raise SystemExit("invalid or writable/executable load segment")
        bss += memsz - filesz
        loads += 1
    if ptype == 0x6474E551 and perms & 1:
        raise SystemExit("executable stack is forbidden")
if loads == 0 or bss > 1024 * 1024:
    raise SystemExit("sender exceeds the QDC507 1 MiB BSS budget")
print(f"target=ARMv7 soft-float static\nbinary_bytes={len(data)}\nbss_bytes={bss}")
