#!/usr/bin/env python3
"""Turn text into QEMU monitor `sendkey` commands, paced so the guest keeps up.

    keys.py 'dir{ret}type readme.txt{ret}'      {ret} means Enter, {wait} pauses a second

Output goes to stdout for piping into `qemu -monitor stdio`. US layout.
"""
import sys
import time

PLAIN = {
    " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal", "[": "bracket_left",
    "]": "bracket_right", ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
    "\\": "backslash", ",": "comma", ".": "dot", "/": "slash",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
    ")": "0", "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right",
    ":": "semicolon", '"': "apostrophe", "~": "grave_accent", "|": "backslash",
    "<": "comma", ">": "dot", "?": "slash",
}


def key_for(ch):
    if ch.isdigit() or ("a" <= ch <= "z"):
        return ch
    if "A" <= ch <= "Z":
        return "shift-" + ch.lower()
    if ch in PLAIN:
        return PLAIN[ch]
    if ch in SHIFTED:
        return "shift-" + SHIFTED[ch]
    raise SystemExit(f"keys.py: no key for {ch!r}")


def main():
    text = sys.argv[1] if len(sys.argv) > 1 else ""
    text = text.replace("{ret}", "\n").replace("{wait}", "\x00")
    for ch in text:
        if ch == "\x00":                    # {wait}: let a slow command finish
            time.sleep(1)
            continue
        print(f"sendkey {key_for(ch)} 20", flush=True)
        # Enter runs a command: give it time to finish before typing on
        time.sleep(0.5 if ch == "\n" else 0.06)


if __name__ == "__main__":
    main()
