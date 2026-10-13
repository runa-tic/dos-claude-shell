# dos-claude-shell

A replacement for `COMMAND.COM`, written in NASM for 386 real mode, that will run on
real DOS (FreeDOS and MS-DOS 6.22) and talk to Claude over its own TCP/IP stack. The
sibling of ClauDOS: there everything under the shell was written from scratch; here DOS
is real and only the shell is ours.

**Status: phase 0, the environment.** `CLAUDE.COM` is still a stub that boots as
`SHELL=`, says which DOS it is on and echoes lines. Everything around it works: both DOSes
boot in QEMU with an NE2000 card and a packet driver, and reach the host.

## Layout
```
src/claude.asm          the shell (a stub for now)
image/freedos/          FDCONFIG.SYS and FDAUTO.BAT for FreeDOS; -claude variant boots our shell
image/msdos/            CONFIG.SYS and AUTOEXEC.BAT for MS-DOS 6.22; -claude variant likewise
image/common/NET/       mTCP's configuration
image/dosbox-x/         a DOSBox-X profile that boots the same images
tests/net.bat           the network check: DHCP, ping the host, HTTP to the host
tools/fetch.sh          downloads FreeDOS 1.4 Lite, the NE2000 driver and mTCP, hash-checked
tools/mkimage.py        a copy of a base disk image with files put onto it (mtools)
tools/boot.py           boots an image headless in QEMU, types at it, reports
tools/keys.py screen.py pcap.py   keystroke injection, screen and packet decoding (from ClauDOS)
```

## Build and run
Needs `nasm`, `qemu-system-i386`, `mtools`, `python3`, and `dosbox-x` for the DOSBox-X
targets (all in Homebrew).
```bash
make fetch          # once: FreeDOS 1.4 Lite (17 MB) and two packages
make run            # FreeDOS in a QEMU window, FreeCOM as the shell, CLAUDE.COM at C:\
make nettest        # headless network check, prints C:\RESULT.TXT
make shelltest      # headless boot with SHELL=\CLAUDE.COM, types a line, prints the screen
make dbx            # FreeDOS in DOSBox-X
make nettest-dbx    # the network check in DOSBox-X, headless
```
Every image is built as a copy: the FreeDOS download and an MS-DOS image are never
written to.

### MS-DOS 6.22
MS-DOS is not free software, so no MS-DOS image or file is in this repository. Point the
build at your own installed image in a `local.mk` (ignored by git):
```make
MSDOS_BASE := /path/to/your/msdos622.img
```
then `make run-msdos`, `nettest-msdos`, `shelltest-msdos`, or `make dbx
DOSBOX_IMG=build/msdos.img`. The image this was developed against boots through its own
MBR menu, so the headless MS-DOS tests press `1` at it.

## How the network is set up
QEMU's `ne2k_isa` (and DOSBox-X's `[ne2000]`) at port `0x300`, IRQ 10. The Crynwr
`NE2000.COM` packet driver is loaded by `INSTALL=` in the config file rather than in a
batch file, so it is resident whichever shell starts, ours included, on software
interrupt `0x60`. Both emulators put the host at `10.0.2.2` on a user-mode network, so the
Claude backend from ClauDOS (claude-p-shim with `SHIM_HOSTS=10.0.2.2`) is reachable
unchanged.

mTCP is on the image only to check the environment (its `DHCP`, `PING` and `HTGET`); the
shell will carry its own TCP/IP in assembly.

## How tests run
A test is a batch file copied onto a fresh image as `C:\TEST.BAT`. The startup file calls
it if it exists; it writes what it sees to `C:\RESULT.TXT` and ends with `FDAPM POWEROFF`,
which stops QEMU and closes DOSBox-X alike (FreeDOS's `FDAPM` also works on MS-DOS 6.22).
The host then reads `RESULT.TXT` off the image with mtools.

## Licences of what the build downloads
FreeDOS 1.4, the Crynwr packet driver and mTCP are fetched at build time and are not
redistributed here; each keeps its own licence (mTCP is GPL v3).
