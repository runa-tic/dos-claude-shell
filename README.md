# dos-claude-shell

A replacement for `COMMAND.COM`, written in NASM for 386 real mode, that will run on
real DOS (FreeDOS and MS-DOS 6.22) and talk to Claude over its own TCP/IP stack. The
sibling of ClauDOS: there everything under the shell was written from scratch; here DOS
is real and only the shell is ours.

**Status: phase 7, the plan is complete: a DOS shell that talks to Claude, who can act in it.** `CLAUDE.COM` (9 KB, about 15 KB resident with
its buffers and a 1 KB environment) boots as the only shell on FreeDOS and MS-DOS 6.22.
It runs `.COM`, `.EXE` and batch files from the current directory or along `PATH`, in
DOS's order, keeping their errorlevel. Ctrl-C ends the running program and offers to end
a batch file. A critical error asks Abort/Retry/Ignore/Fail, offering only what DOS
allows. `/P`, `/C`, `/K`, `/D` and `/E:n` work as in `COMMAND.COM`.

Its own commands: `DIR` (`/W /B /P /A`), `CD`, `MD`, `RD`, `COPY` (wildcards, `*.TXT
*.BAK` templates, joining into one file, `COPY CON`), `DEL`, `REN`, `TYPE`, `ECHO`,
`SET`, `PATH`, `PROMPT` (the `$` codes), `CLS`, `VER`, `VOL`, `DATE`, `TIME`, `BREAK`,
`VERIFY`, `TRUENAME`, `PAUSE`, `LH`, `EXIT` and `REM`. Error messages go to stderr, as
both `COMMAND.COM` and FreeCOM do. Started by DOS, it sets `COMSPEC` to itself, so
programs that shell out come back to it.

Batch files have the whole MS-DOS 6.22 language: `%0`-`%9`, `%VAR%`, `%%`, `IF [NOT]
ERRORLEVEL | EXIST | ==`, `GOTO`, `CALL` (nested up to 8 deep), `FOR %%V IN (...) DO`
with wildcards, `SHIFT`, `ECHO OFF` and `@`. A test batch file using all of it gives the
same output under this shell as under MS-DOS's `COMMAND.COM`, blank lines included.

Every line can use `<`, `>`, `>>` and `|`. Pipes go through temporary files in `%TEMP%`,
as in DOS, and redirecting an `IF` or `FOR` line redirects the whole of it.

It can replace `COMMAND.COM` completely: with `SHELL=\CLAUDE.COM /E:2048 /P=\FDAUTO.BAT`
(or `SHELL=C:\CLAUDE.COM /P` on MS-DOS) it runs the system's real startup file, and the
test batch files, the network check included, run under it with no other shell on the
machine (`make roottest`, `make rootnet`, and their `-msdos` versions).

It has its own TCP/IP, in assembly, over any packet driver: Ethernet, ARP, IPv4, ICMP,
UDP, DHCP, DNS and a TCP client. `NET` shows the card and the address (from DHCP, or
`ip=`, `mask=`, `gateway=`, `dns=` in `CLAUDE.CFG` beside the shell), `PING host` pings,
and `FETCH http://host[:port]/path` prints an HTTP answer. The packet driver is only held
while one of them runs, so mTCP and other programs can use the card in between.

**Claude.** `ASK question` sends a question to Claude, and so does any line typed at the
prompt that is not a command (in a batch file it is still "Bad command or file name").
The answer is printed wrapped to 80 columns. The conversation is remembered between
questions until `NEW`. It goes over our own TCP/IP to the Messages API endpoint named in
`CLAUDE.CFG` beside the shell:

```
url=http://10.0.2.2:8765/v1/messages
model=claude-haiku-5-5
```

with the key in `CLAUDE.KEY` beside it. The endpoint used in development is
[claude-p-shim](https://github.com/runa-tic/claude-p-shim) on the host, started with
`SHIM_HOSTS=10.0.2.2`; both emulators show the host as 10.0.2.2. There is no TLS, so it
speaks plain HTTP only.

**Claude acts.** Claude can run a command line in the shell and read what it printed
(`run`), or write a text file (`write_file`). You see every command and its output. Only
a few read-only commands run without asking: `DIR`, `TYPE`, `VER`, `VOL`, `TRUENAME`,
`CD`, `MEM`, `ECHO` and `REM`, and `SET` or `PATH` with nothing to set, all with nothing
redirected or piped. Anything else is shown first with "Allow it? (Y/N)". The answer is
read from the keyboard itself, after emptying the keyboard buffer, so neither type-ahead
nor redirected input can answer for you. While Claude acts, batch files, the network
commands, `ASK` and `EXIT` are refused.

## Layout
```
src/claude.asm          the shell: start-up, the loop, running programs, batch files,
                        Ctrl-C and critical errors
src/cmds.asm            the internal commands but DIR and COPY, which have files of their own
src/dir.asm src/copy.asm
src/batch.asm           batch files: % expansion, CALL, GOTO, SHIFT, IF, FOR
src/redir.asm           redirection and pipes
src/net.asm             packet driver, ARP, IP, ICMP, UDP, DHCP, DNS; NET and PING
src/tcp.asm             a TCP client, HTTP over it; FETCH
src/chat.asm            Claude: the request, the conversation, the answer; ASK, NEW
src/json.asm            enough JSON to read the answer
src/tools.asm           Claude's actions, run and write_file, and the Y/N gate
src/env.asm             the shell's own environment block
src/util.asm            text, numbers, dates and file names
image/freedos/          FDCONFIG.SYS and FDAUTO.BAT for FreeDOS; -claude variant boots our shell
image/msdos/            CONFIG.SYS and AUTOEXEC.BAT for MS-DOS 6.22; -claude variant likewise
image/common/NET/       mTCP's configuration
image/dosbox-x/         a DOSBox-X profile that boots the same images
tests/net.bat           the network check: DHCP, ping the host, HTTP to the host
tests/child.bat         the shell run by the system's own shell: PATH, errorlevels, input files
tests/hello.asm         HELLO.COM: prints its command tail, memory and FCB; HELLO WAIT waits
tests/hellox.asm        HELLOX.EXE: a hand-made MZ executable
tests/p2.bat            the internal commands, run by our shell and by the system's for comparison
tests/p3.bat            the batch language, likewise (with p3sub.bat for CALL)
tests/p4.bat            redirection and pipes, likewise; tests/upper.asm is a filter for them
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
make cmdtest        # headless: tests/p2-p4.bat under CLAUDE.COM and under FreeCOM, both printed
make roottest       # headless: CLAUDE.COM the only shell, FDAUTO.BAT calls the child test
make rootnet        # the same with the network check
make net5test       # NET, PING and FETCH under CLAUDE.COM alone (also -msdos, -dbx);
                    # its 40 KB download wants a web server on the host's port 8766
make asktest        # ASK, the conversation, NEW, through the shim (also -msdos);
                    # set SHIM_KEY := path/to/the/key in local.mk
make asktype        # questions typed at the prompt, the screen printed
make tooltest       # Claude looks (DIR), writes a file (Y), may not delete it (N) (also -msdos)
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
then `make run-msdos`, `nettest-msdos`, `shelltest-msdos`, `childtest-msdos`,
`cmdtest-msdos`, or `make dbx
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
check the errorlevels itself; it also runs in DOSBox-X (`childtest-dbx`), where nothing
can type. `cmdtest` (and `cmdtest-dbx`) runs the same batch file of internal commands
under our shell and under the system's own, each in an empty directory, and prints both:
the system's shell is the reference. Neither reference writes its error messages to
stdout, which is how we learned ours should go to stderr too.

## Licences of what the build downloads
FreeDOS 1.4, the Crynwr packet driver and mTCP are fetched at build time and are not
redistributed here; each keeps its own licence (mTCP is GPL v3).
