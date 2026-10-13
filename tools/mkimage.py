#!/usr/bin/env python3
"""Make a DOS disk image: a copy of a base image with files put onto it.

    mkimage.py OUT BASE [HOST=DOSPATH ...] [-d DOSPATH ...]

BASE is any MBR-partitioned FAT disk image (the FreeDOS Lite USB image, an
MS-DOS install); its first partition is used, and BASE itself is never written.
HOST=DOSPATH copies a host file onto the image, making directories on the way;
.SYS, .BAT, .CFG and .TXT files are converted to CR LF line endings, which
MS-DOS batch files need. -d DOSPATH deletes a file if it is there. Needs mtools.
"""
import os
import shutil
import struct
import subprocess
import sys

TEXT = (".sys", ".bat", ".cfg", ".txt")


def partition_offset(path):
    """Byte offset of the first partition in an MBR disk image."""
    with open(path, "rb") as f:
        mbr = f.read(512)
    if mbr[510:512] != b"\x55\xaa":
        raise SystemExit(f"{path}: no MBR signature")
    for i in range(4):
        entry = mbr[446 + 16 * i: 462 + 16 * i]
        if entry[4]:
            return struct.unpack("<I", entry[8:12])[0] * 512
    raise SystemExit(f"{path}: no partition")


def mtools(*args):
    r = subprocess.run(args, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)
    out, base, rest = args[0], args[1], args[2:]
    if os.path.abspath(out) == os.path.abspath(base):
        raise SystemExit("refusing to write over the base image")
    tmp = out + ".tmp"
    shutil.copyfile(base, tmp)
    disk = f"{tmp}@@{partition_offset(tmp)}"

    i = 0
    while i < len(rest):
        item = rest[i]
        if item == "-d":
            mtools("mdel", "-i", disk, "::/" + rest[i + 1])
            i += 2
            continue
        host, dos = item.split("=", 1)
        dos = dos.replace("\\", "/").upper()
        parts = dos.split("/")[:-1]
        for n in range(1, len(parts) + 1):
            mtools("mmd", "-i", disk, "::/" + "/".join(parts[:n]))     # fails harmlessly if it exists
        flags = ["-t"] if dos.lower().endswith(TEXT) else []
        code, msg = mtools("mcopy", "-o", *flags, "-i", disk, host, "::/" + dos)
        if code:
            os.remove(tmp)
            raise SystemExit(f"mcopy {host} -> {dos}: {msg}")
        i += 1
    os.replace(tmp, out)


if __name__ == "__main__":
    main()
