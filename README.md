# dos-claude-shell

A replacement for `COMMAND.COM`, written in NASM for 386 real mode, that will run on
real DOS (FreeDOS and MS-DOS 6.22) and talk to Claude over its own TCP/IP stack. The
sibling of ClauDOS: there everything under the shell was written from scratch; here DOS
is real and only the shell is ours.

**Status: phase 1, the shell core.** `CLAUDE.COM` (under 3 KB, about 2.5 KB resident)
boots as the only shell on FreeDOS and MS-DOS 6.22 and runs programs: `.COM`, `.EXE` and
batch files, from the current directory or along `PATH` in DOS's order, with their
errorlevel kept. Ctrl-C ends the running program (and offers to end a batch file), a
critical error asks Abort/Retry/Ignore/Fail as DOS allows, and `/P`, `/C`, `/K` and `/D`
work as in `COMMAND.COM`. Internal commands so far: `EXIT`, `REM` and drive changes; the
rest (`DIR`, `CD`, `SET`, ...) is phase 2, batch language phase 3, redirection phase 4,
then the network and Claude. Not Claude yet, in other words: a small DOS shell.

## Layout
```
src/claude.asm          the shell
image/freedos/          FDCONFIG.SYS and FDAUTO.BAT for FreeDOS; -claude variant boots our shell
image/msdos/            CONFIG.SYS and AUTOEXEC.BAT for MS-DOS 6.22; -claude variant likewise
image/common/NET/       mTCP's configuration
image/dosbox-x/         a DOSBox-X profile that boots the same images
tests/net.bat           the network check: DHCP, ping the host, HTTP to the host
tests/child.bat         the shell run by the system's own shell: PATH, errorlevels, input files
tests/hello.asm         HELLO.COM: prints its command tail, memory and FCB; HELLO WAIT waits
tests/hellox.asm        HELLOX.EXE: a hand-made MZ executable
tests/*.bat, *.txt      batch files and input for the tests
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
make shelltest      # headless: CLAUDE.COM as the only shell, typed at, screens printed
make childtest      # headless: FreeCOM runs CLAUDE.COM /C ... as a child, C:\RESULT.TXT printed
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
then `make run-msdos`, `nettest-msdos`, `shelltest-msdos`, `childtest-msdos`, or `make dbx
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

`shelltest` boots with `SHELL=\CLAUDE.COM /P=\STARTUP.BAT`, so no other shell is on the
machine, and types at it through QEMU's monitor (`tools/boot.py --keys`, where
`{key:ctrl-c}` presses any key and `{screen}` snapshots the screen). It runs a program,
interrupts one with Ctrl-C, interrupts a batch file, and answers a critical error on the
empty floppy drive. `childtest` has the system's own shell run `CLAUDE.COM /C ...` and
check the errorlevels itself, which makes it the one test that also runs in DOSBox-X
(`childtest-dbx`), where nothing can type.

## Licences of what the build downloads
FreeDOS 1.4, the Crynwr packet driver and mTCP are fetched at build time and are not
redistributed here; each keeps its own licence (mTCP is GPL v3).
