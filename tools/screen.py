#!/usr/bin/env python3
"""Print an 80x25 VGA text-mode dump (pmemsave 0xb8000 4000) as plain text."""
import sys

data = open(sys.argv[1], "rb").read()
for row in range(25):
    chars = data[row * 160:(row + 1) * 160:2]
    print("".join(chr(c) if 32 <= c < 127 else " " for c in chars).rstrip())
