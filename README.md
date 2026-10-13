# dos-claude-shell

`CLAUDE.COM`: a replacement for `COMMAND.COM`, written in NASM for 386 real mode, that
runs on real DOS (FreeDOS and MS-DOS 6.22) and talks to Claude over its own TCP/IP stack.
The sibling of ClauDOS: there everything under the shell was written from scratch; here
DOS is real and only the shell is ours.

```
C:\>which files are in the root directory
Claude runs: DIR C:\
 ...
The root directory C:\ holds 7 files and 4 directories. ...

C:\>create a file NOTE.TXT that says hello from claude
Claude wants to write C:\NOTE.TXT (18 bytes)
Allow it? (Y/N) Y
Created C:\NOTE.TXT with the text "hello from claude".
```

**Status: all seven planned phases are done.** It boots as the only shell on FreeDOS
and MS-DOS 6.22, runs the systems' own startup files, and is tested under QEMU on both
and under DOSBox-X on FreeDOS. It is 22 KB, and programs get about 557K with it as the
shell (612K under `COMMAND.COM`).

## Try it
Needs `nasm`, `qemu-system-i386`, `mtools`, `python3`, and `dosbox-x` for the DOSBox-X
targets (all in Homebrew), and for Claude a Messages API endpoint the emulator can reach.
Development used [claude-p-shim](https://github.com/runa-tic/claude-p-shim) on the host,
started with `SHIM_HOSTS=10.0.2.2` (both emulators show the host as 10.0.2.2), and its
key named in a `local.mk` (ignored by git):
```make
SHIM_KEY := /path/to/the/shim/key
```
```bash
make fetch          # once: FreeDOS 1.4 Lite (17 MB), the NE2000 packet driver, mTCP
make play           # FreeDOS in a QEMU window, CLAUDE.COM the only shell, Claude set up
make play-msdos     # the same on your own MS-DOS 6.22 image (see below)
make play-dbx       # the same in DOSBox-X
```
Each starts from a fresh copy of the image (`build/play.img`), so do anything to it. Type
DOS commands as usual; type a question, or anything that is not a command, and it goes to
Claude. `ASK question` asks even when the line starts with a command's name, `NEW`
forgets the conversation, `NET` shows the network, `PING` and `FETCH` use it.

## What it does
**A DOS shell.** It runs `.COM`, `.EXE` and batch files from the current directory or
along `PATH`, in DOS's order, keeping their errorlevel. Ctrl-C ends the running program
and offers to end a batch file. A critical error asks Abort/Retry/Ignore/Fail, offering
only what DOS allows. `/P[=file]`, `/C`, `/K`, `/D` and `/E:n` work as in `COMMAND.COM`.
Started by DOS it is permanent, and sets `COMSPEC` to itself so programs that shell out
come back to it. Its environment is its own block, inherited by the programs it runs.

Its own commands: `DIR` (`/W /B /P /A`), `CD`, `MD`, `RD`, `COPY` (wildcards, `*.TXT
*.BAK` templates, joining into one file, `COPY CON`), `DEL`, `REN`, `TYPE`, `ECHO`,
`SET`, `PATH`, `PROMPT` (the `$` codes), `CLS`, `VER`, `VOL`, `DATE`, `TIME`, `BREAK`,
`VERIFY`, `TRUENAME`, `PAUSE`, `LH`, `EXIT`, `REM`, and drive changes. Error messages go
to stderr, as both `COMMAND.COM` and FreeCOM do.

Batch files have the MS-DOS 6.22 language: `%0`-`%9`, `%VAR%`, `%%`, `IF [NOT]
ERRORLEVEL | EXIST | ==`, `GOTO`, `CALL` (8 deep), `FOR %%V IN (...) DO` with wildcards,
`SHIFT`, `ECHO OFF` and `@`. Every line can use `<`, `>`, `>>` and `|`; pipes go through
temporary files in `%TEMP%`, as in DOS.

**Its own TCP/IP**, in assembly, over any packet driver: Ethernet, ARP, IPv4, ICMP, UDP,
DHCP, DNS and a TCP client. The address comes from DHCP, or from `ip=`, `mask=`,
`gateway=` and `dns=` in `CLAUDE.CFG` beside the shell. The packet driver is only held
while a network command runs, so mTCP and other programs can use the card in between.

**Claude**, through the Messages API endpoint named in `CLAUDE.CFG` beside the shell,
with the key in `CLAUDE.KEY` beside it:
```
url=http://10.0.2.2:8765/v1/messages
model=claude-haiku-5-5
```
There is no TLS, so plain HTTP only. The answer is printed wrapped to 80 columns, and
the conversation is kept until `NEW`, the oldest turns going when it outgrows its 24 KB.
In a batch file a line that is not a command is still "Bad command or file name".

**Claude acts**: it can run a command line here and read what it printed (`run`), or
write a text file (`write_file`). You see every command and its output. Only a few
read-only commands run without asking (`DIR`, `TYPE`, `VER`, `VOL`, `TRUENAME`, `CD`,
`MEM`, `ECHO`, `REM`, and `SET` or `PATH` with nothing to set, nothing redirected or
piped). Anything else is shown first with "Allow it? (Y/N)", answered at the keyboard
itself after the keyboard buffer is emptied, so neither type-ahead nor redirected input
can answer for you. While Claude acts, batch files, the network commands, `ASK` and
`EXIT` are refused.

## As the system shell
In `FDCONFIG.SYS` (FreeDOS) or `CONFIG.SYS` (MS-DOS):
```
SHELL=\CLAUDE.COM /E:2048 /P=\FDAUTO.BAT
SHELL=C:\CLAUDE.COM /P
```
`image/freedos/fdconfig-root.sys` and `image/msdos/config-root.sys` are complete examples,
with the packet driver loaded by `INSTALL=` so it is there whichever shell starts.

## Layout
```
src/claude.asm          start-up, the loop, running programs, Ctrl-C and critical errors
src/cmds.asm            the internal commands but DIR and COPY, which have files of their own
src/dir.asm copy.asm
src/batch.asm           batch files: % expansion, CALL, GOTO, SHIFT, IF, FOR
src/redir.asm           redirection and pipes
src/env.asm             the shell's own environment block
src/net.asm             packet driver, ARP, IP, ICMP, UDP, DHCP, DNS; NET and PING
src/tcp.asm             a TCP client, HTTP over it; FETCH
src/chat.asm            Claude: the request, the conversation, the answer; ASK, NEW
src/json.asm            enough JSON to read the answer
src/tools.asm           Claude's actions, run and write_file, and the Y/N gate
src/util.asm            text, numbers, dates and file names
image/                  config and startup files for each DOS, CLAUDE.CFG, a DOSBox-X profile
tests/                  test batch files, their input, and three tiny test programs
tools/fetch.sh          downloads FreeDOS 1.4 Lite, the NE2000 driver and mTCP, hash-checked
tools/mkimage.py        a copy of a base disk image with files put onto it (mtools)
tools/boot.py           boots an image headless in QEMU, types at it, reports
tools/keys.py screen.py pcap.py   keystroke injection, screen and packet decoding
```

## Tests
All headless. A test is a batch file put on a fresh image as `C:\TEST.BAT`; the startup
file calls it, it writes `C:\RESULT.TXT` and ends with `FDAPM POWEROFF` (FreeDOS's, which
also works on MS-DOS), and the host reads the result off the image. Tests that type use
QEMU's monitor (`tools/boot.py --keys`, with `{key:ctrl-c}` and `{screen}`).
```bash
make shelltest      # CLAUDE.COM the only shell, typed at: programs, Ctrl-C, critical errors,
                    # CLS, SET, PROMPT, DATE, TIME, COPY CON, ECHO OFF; screens printed
make childtest      # the system's shell runs CLAUDE.COM /C: PATH, errorlevels, input files
make cmdtest        # tests/p2-p4.bat (commands, batch language, redirection and pipes)
                    # under CLAUDE.COM and under the system's own shell, both printed
make roottest       # CLAUDE.COM the only shell; the real FDAUTO.BAT calls the child test
make rootnet        # the same with the mTCP network check
make net5test       # NET, PING, FETCH, and a 40 KB download (wants a web server on the
                    # host's port 8766 serving big.txt)
make asktest        # ASK, the conversation remembering, NEW
make asktype        # questions typed at the prompt
make tooltest       # Claude looks (DIR), writes a file (Y), is refused DEL (N)
```
Most have `-msdos` versions, and `childtest-dbx`, `cmdtest-dbx`, `net5test-dbx`,
`asktest-dbx` run in DOSBox-X. The reference for `cmdtest` is the system's own shell:
the output matches `COMMAND.COM` on MS-DOS line for line; FreeCOM differs only in how it
echoes `FOR`. Every image is a copy: the FreeDOS download and your MS-DOS image are never
written to.

### MS-DOS 6.22
MS-DOS is not free software, so no MS-DOS image or file is in this repository. Point the
build at your own installed image in `local.mk`:
```make
MSDOS_BASE := /path/to/your/msdos622.img
```
The image this was developed against boots through its own MBR menu, so the headless
MS-DOS tests press `1` at it.

## How the network is set up
QEMU's `ne2k_isa` (and DOSBox-X's `[ne2000]`) at port `0x300`, IRQ 10, with Crynwr's
`NE2000.COM` packet driver on software interrupt `0x60`. Both emulators put the host at
`10.0.2.2` on a user-mode network. The shell sends `Host:` without a port, as mTCP and
ClauDOS do: claude-p-shim compares it exactly with its `SHIM_HOSTS` list. mTCP is on the
images only to check the environment.

## Licences of what the build downloads
FreeDOS 1.4, the Crynwr packet driver and mTCP are fetched at build time and are not
redistributed here; each keeps its own licence (mTCP is GPL v3).
