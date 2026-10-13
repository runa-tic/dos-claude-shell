#!/usr/bin/env python3
"""Boot a DOS disk image headless in QEMU, optionally type at it, and report.

    boot.py IMAGE [--timeout S] [--keys TEXT] [--screen] [--result DOSPATH]

The machine runs until it powers itself off (a test batch file ends with
FDAPM POWEROFF) or the timeout passes. --keys types at it once it has booted
({ret} is Enter, {wait} a one-second pause). --screen prints the 80x25 text
screen as it was at the end, which needs the timeout to end the run: a machine
that powered off has no screen left. --result prints a file the run left on
the disk, read back with mtools. Every frame on the network is captured to
build/net.pcap (tools/pcap.py prints it).
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from keys import key_for          # noqa: E402
from mkimage import partition_offset  # noqa: E402

BUILD = os.path.join(HERE, "..", "build")
NET = ["-netdev", "user,id=n0", "-device", "ne2k_isa,netdev=n0,iobase=0x300,irq=10",
       "-object", f"filter-dump,id=d0,netdev=n0,file={os.path.join(BUILD, 'net.pcap')}"]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("image")
    p.add_argument("--timeout", type=float, default=60)
    p.add_argument("--boot-wait", type=float, default=6, help="seconds before typing")
    p.add_argument("--keys", default="")
    p.add_argument("--screen", action="store_true")
    p.add_argument("--result")
    a = p.parse_args()

    vga = os.path.join(BUILD, "vga.bin")
    if os.path.exists(vga):
        os.remove(vga)
    cmd = ["qemu-system-i386", "-m", "16", "-rtc", "base=localtime", "-no-reboot",
           "-drive", f"format=raw,file={a.image}", *NET, "-display", "none", "-monitor", "stdio"]
    monitor_log = open(os.path.join(BUILD, "monitor.log"), "w")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=monitor_log,
                            stderr=subprocess.STDOUT, text=True)

    def send(line):
        try:
            proc.stdin.write(line + "\n")
            proc.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    start = time.time()
    if a.keys:
        time.sleep(a.boot_wait)
        for ch in a.keys.replace("{ret}", "\n").replace("{wait}", "\0"):
            if ch == "\0":
                time.sleep(1)
                continue
            send(f"sendkey {key_for(ch)} 20")
            time.sleep(0.4 if ch == "\n" else 0.06)

    while proc.poll() is None and time.time() - start < a.timeout:
        time.sleep(0.2)
    if proc.poll() is None:
        ended = "timeout"
        if a.screen:
            # relative: the monitor would read a leading "/" as a division
            send(f"pmemsave 0xb8000 4000 {os.path.relpath(vga)}")
            time.sleep(1)
        send("quit")
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill()
    else:
        ended = "the machine powered off"
    print(f"[boot] ended by {ended} after {time.time() - start:.0f} s")

    if a.screen and os.path.exists(vga):
        data = open(vga, "rb").read()
        for row in range(25):
            line = "".join(chr(data[(row * 80 + c) * 2]) if 32 <= data[(row * 80 + c) * 2] < 127 else " "
                           for c in range(80))
            print(line.rstrip())
    if a.result:
        r = subprocess.run(["mtype", "-i", f"{a.image}@@{partition_offset(a.image)}", "::/" + a.result],
                           capture_output=True, text=True, errors="replace")
        print(r.stdout.replace("\r", "") if r.returncode == 0 else f"[boot] no {a.result}: {r.stderr.strip()}")


if __name__ == "__main__":
    main()
