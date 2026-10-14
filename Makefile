## dos-claude-shell build. Needs nasm, qemu-system-i386, mtools and python3.
##
##   make              build/claude.com, the shell
##   make play         try it: FreeDOS in a QEMU window, CLAUDE.COM the only shell, Claude
##                     set up (play-msdos, play-dbx likewise; the key: SHIM_KEY in local.mk)
##   make fetch        download FreeDOS 1.4 Lite, the NE2000 packet driver and mTCP (hash-checked)
##   make freedos      build/freedos.img: FreeDOS with FreeCOM, the network, and CLAUDE.COM beside it
##   make run          boot that in a QEMU window; the console is kept in logs/
##   make nettest      headless: DHCP, ping the host, TCP to the shim, printed from C:\RESULT.TXT
##   make shelltest    headless: boot with SHELL=\CLAUDE.COM as the only shell, type at it,
##                     print the screens (programs, Ctrl-C, a critical error, batch files)
##   make childtest    headless: the system shell runs CLAUDE.COM /C ... as a child; PATH
##                     search, errorlevels, input from a file; printed from C:\RESULT.TXT
##   make msdos ...    the same on a copy of your own MS-DOS 6.22 image (msdos, run-msdos,
##                     nettest-msdos, shelltest-msdos, childtest-msdos); set MSDOS_BASE in local.mk
##   make dbx          boot FreeDOS in a DOSBox-X window (DOSBOX_IMG=build/msdos.img for MS-DOS)
##   make nettest-dbx  the network test in DOSBox-X, headless (childtest-dbx likewise)
##
## Every image is a copy: the FreeDOS download and your MS-DOS image are never written.

-include local.mk

BUILD   := build
PKG     := $(BUILD)/pkg
FD_BASE := $(BUILD)/fd14lite.img
SHELL_COM := $(BUILD)/claude.com
MKIMAGE := python3 tools/mkimage.py
BOOT    := python3 tools/boot.py
BOCHS   := $(BUILD)/bochs/bin/bochs
# The root configs start the shell with /L, which copies the console to COM1;
# each emulator writes COM1 to a file: logs/console-<time>.log when playing.
CONLOG   = $$PWD/logs/console-$$(date +%Y%m%d-%H%M%S).log
BOCHSRC  = sed -e "s\#%IMG%\#$$PWD/$(1)\#" -e "s\#%LOG%\#$$PWD/$(BUILD)/bochs.log\#" -e "s\#%DISPLAY%\#$(2)\#" \
               -e "s\#%CONLOG%\#$(3)\#" image/bochs/bochsrc
DBXCONF  = sed -e "s\#%IMG%\#$$PWD/$(1)\#" -e "s\#%CONLOG%\#$(2)\#" image/dosbox-x/boot.conf

QEMU    := qemu-system-i386 -m 16 -rtc base=localtime \
           -netdev user,id=n0 -device ne2k_isa,netdev=n0,iobase=0x300,irq=10 \
           -object filter-dump,id=d0,netdev=n0,file=$(BUILD)/net.pcap

NETFILES = $(PKG)/DRIVERS/CRYNWR/NE2000.COM=NET/NE2000.COM \
           image/common/NET/MTCP.CFG=NET/MTCP.CFG \
           $(PKG)/NET/mTCP/dhcp.exe=NET/DHCP.EXE \
           $(PKG)/NET/mTCP/ping.exe=NET/PING.EXE \
           $(PKG)/NET/mTCP/htget.exe=NET/HTGET.EXE \
           $(PKG)/NET/mTCP/nc.exe=NET/NC.EXE

.PHONY: all fetch freedos play play-msdos play-dbx play-bochs play-bochs-fd bochs asktest-bochs run nettest shelltest childtest cmdtest msdos run-msdos nettest-msdos \
        shelltest-msdos childtest-msdos cmdtest-msdos roottest rootnet roottest-msdos rootnet-msdos net5test net5test-msdos asktest asktest-msdos asktype tooltest tooltest-msdos dbx nettest-dbx childtest-dbx cmdtest-dbx net5test-dbx asktest-dbx clean

all: $(SHELL_COM)

$(BUILD):
	mkdir -p $(BUILD)

$(SHELL_COM): src/*.asm | $(BUILD)
	nasm -f bin -i src/ -o $@ src/claude.asm

# Test programs: HELLO.COM prints its tail and memory, HELLOX.EXE is a hand-made MZ,
# UPPER.COM a filter for pipes.
$(BUILD)/hello.com: tests/hello.asm | $(BUILD)
	nasm -f bin -o $@ $<

$(BUILD)/hellox.exe: tests/hellox.asm | $(BUILD)
	nasm -f bin -o $@ $<

$(BUILD)/upper.com: tests/upper.asm | $(BUILD)
	nasm -f bin -o $@ $<

$(BUILD)/hang.com: tests/hang.asm | $(BUILD)
	nasm -f bin -o $@ $<

TESTPROGS = $(BUILD)/hello.com $(BUILD)/hellox.exe $(BUILD)/upper.com $(BUILD)/hang.com
T_FILES = $(BUILD)/hello.com=T/HELLO.COM $(BUILD)/hellox.exe=T/HELLOX.EXE $(BUILD)/upper.com=T/UPPER.COM \
          $(BUILD)/hang.com=T/HANG.COM \
          $(BUILD)/hello.com=T/PICK.COM $(BUILD)/hellox.exe=T/PICK.EXE \
          $(BUILD)/hellox.exe=T/PICK2.EXE tests/pick2.bat=T/PICK2.BAT \
          tests/sub.bat=T/SUB.BAT tests/slow.bat=T/SLOW.BAT \
          tests/input.txt=T/INPUT.TXT tests/noexit.txt=T/NOEXIT.TXT tests/startup.bat=STARTUP.BAT \
          tests/p2.bat=T/P2.BAT tests/p3.bat=T/P3.BAT tests/p3sub.bat=T/P3SUB.BAT tests/p4.bat=T/P4.BAT

# What shelltest types: a program, EXIT (ignored, the shell is permanent), Ctrl-C in a
# program and at the prompt, a bad drive, a batch file, Ctrl-C in a batch file, and a
# critical error on the empty floppy drive answered Fail and then Abort (the $P prompt
# reads the drive too, so it asks once more, as COMMAND.COM does). The root shell
# has no PATH, so programs are named by path. Make would put spaces between continued
# lines, so the keys are glued together from pieces.
K1 = t\hello typed{ret}{wait}exit{ret}t\hello wait{ret}{wait}{key:ctrl-c}{wait}
K2 = abc{key:ctrl-c}{wait}q:{ret}{wait}t\sub{ret}{wait}{wait}{screen}
K3 = t\slow{ret}{wait}{wait}{key:ctrl-c}{wait}y{wait}{wait}a:{ret}{wait}{wait}{wait}{wait}{wait}{wait}f{wait}{wait}
K4 = hello{ret}{wait}{wait}{wait}{wait}{wait}{wait}a{wait}{wait}{wait}{wait}{wait}{wait}f{wait}{wait}c:{ret}{wait}t\hello back{ret}{wait}{screen}
# Then phase 2 at the keyboard: CLS, SET at the root (COMSPEC is us), PROMPT codes ($$ is
# Make's way of writing $),
# DATE with a bad date first, TIME, COPY CON ended by Ctrl-Z, TYPE, ECHO OFF at the prompt.
K5 = cls{ret}set{ret}{wait}prompt $$n$$q$$t$$g{ret}date{ret}{wait}13-45-99{ret}{wait}{ret}{wait}time{ret}{wait}{ret}{wait}{screen}
K6 = prompt{ret}cls{ret}copy con t\typed.txt{ret}{wait}first line{ret}second line{ret}{key:ctrl-z}{ret}{wait}{wait}
K7 = type t\typed.txt{ret}{wait}echo off{ret}ver{ret}{wait}echo on{ret}dir t\*.txt /b{ret}{wait}
ROOT_KEYS = $(K1)$(K2)$(K3)$(K4)$(K5)$(K6)$(K7)

fetch:
	sh tools/fetch.sh

downloads/%.zip:
	sh tools/fetch.sh

$(FD_BASE): downloads/FD14-LiteUSB.zip | $(BUILD)
	unzip -p $< FD14LITE.img > $@

$(PKG)/.done: downloads/crynwr.zip downloads/mtcp.zip $(FD_BASE) | $(BUILD)
	rm -rf $(PKG) && mkdir -p $(PKG)
	unzip -q -o downloads/crynwr.zip -d $(PKG)
	unzip -q -o downloads/mtcp.zip -d $(PKG)
	mcopy -i $(FD_BASE)@@32256 ::/FREEDOS/BIN/FDAPM.COM $(PKG)/FDAPM.COM
	touch $@

# ---- FreeDOS ----

FD_FILES = image/freedos/fdconfig.sys=FDCONFIG.SYS image/freedos/fdauto.bat=FDAUTO.BAT \
           $(NETFILES) $(SHELL_COM)=CLAUDE.COM -d SETUP.BAT

$(BUILD)/freedos.img: $(FD_BASE) $(PKG)/.done $(SHELL_COM) image/freedos/* image/common/NET/MTCP.CFG tools/mkimage.py
	$(MKIMAGE) $@ $(FD_BASE) $(FD_FILES)

freedos: $(BUILD)/freedos.img

# The way to try it: CLAUDE.COM the only shell, the network up, Claude set up (url and
# model in CLAUDE.CFG; the key from SHIM_KEY in local.mk), in a QEMU window. A fresh copy
# every time: build/play.img, changed as you like and thrown away on the next run.
play: $(BUILD)/freedos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/play.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS $(CLAUDE_FILES) $(T_FILES)
	@mkdir -p logs
	$(QEMU) -drive format=raw,file=$(BUILD)/play.img -serial file:logs/console-$$(date +%Y%m%d-%H%M%S).log

play-msdos: $(BUILD)/msdos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/play-msdos.img $< image/msdos/config-root.sys=CONFIG.SYS $(CLAUDE_FILES) $(T_FILES)
	@mkdir -p logs
	$(QEMU) -drive format=raw,file=$(BUILD)/play-msdos.img -serial file:logs/console-$$(date +%Y%m%d-%H%M%S).log

play-dbx: $(BUILD)/freedos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/play.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS $(CLAUDE_FILES) $(T_FILES)
	@mkdir -p logs
	$(call DBXCONF,$(BUILD)/play.img,$(CONLOG)) > $(BUILD)/play-dbx.conf
	dosbox-x -conf $(BUILD)/play-dbx.conf

# Bochs: built here with the NE2000 (Homebrew's has no network card).
$(BOCHS):
	sh tools/build-bochs.sh

bochs: $(BOCHS)

play-bochs: $(BUILD)/msdos.img $(TESTPROGS) $(BOCHS)
	$(MKIMAGE) $(BUILD)/play-bochs.img $< image/msdos/config-root.sys=CONFIG.SYS $(CLAUDE_FILES) $(T_FILES)
	@mkdir -p logs
	$(call BOCHSRC,$(BUILD)/play-bochs.img,sdl2,$(CONLOG)) > $(BUILD)/play-bochs.rc
	$(BOCHS) -q -f $(BUILD)/play-bochs.rc

play-bochs-fd: $(BUILD)/freedos.img $(TESTPROGS) $(BOCHS)
	$(MKIMAGE) $(BUILD)/play-bochs.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS $(CLAUDE_FILES) $(T_FILES)
	@mkdir -p logs
	$(call BOCHSRC,$(BUILD)/play-bochs.img,sdl2,$(CONLOG)) > $(BUILD)/play-bochs.rc
	$(BOCHS) -q -f $(BUILD)/play-bochs.rc

run: $(BUILD)/freedos.img
	@mkdir -p logs
	$(QEMU) -drive format=raw,file=$< -serial file:logs/console-$$(date +%Y%m%d-%H%M%S).log

# The test images are made fresh for every run, since a run writes to its disk.
nettest: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/freedos-test.img $< tests/net.bat=TEST.BAT
	$(BOOT) $(BUILD)/freedos-test.img --timeout 120 --result RESULT.TXT

shelltest: $(BUILD)/freedos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/freedos-test.img $< image/freedos/fdconfig-claude.sys=FDCONFIG.SYS $(T_FILES)
	$(BOOT) $(BUILD)/freedos-test.img --timeout 130 --keys '$(ROOT_KEYS)' --screen

# The internal commands: tests/p2.bat run by CLAUDE.COM, then by the system's own shell
# as the reference, each in an empty directory; both outputs are printed.
cmdtest: $(BUILD)/freedos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/freedos-test.img $< tests/cmds.bat=TEST.BAT $(T_FILES)
	$(BOOT) $(BUILD)/freedos-test.img --timeout 120 --result OURS.TXT REF.TXT OURS3.TXT REF3.TXT OURS4.TXT REF4.TXT

childtest: $(BUILD)/freedos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/freedos-test.img $< tests/child.bat=TEST.BAT $(T_FILES)
	$(BOOT) $(BUILD)/freedos-test.img --timeout 120 --result RESULT.TXT

# CLAUDE.COM as the only shell, running the real startup file (FDAUTO.BAT, or
# AUTOEXEC.BAT on MS-DOS), which calls the test: every redirection, errorlevel and
# batch line in it is ours. roottest runs the child test, rootnet the network check.
roottest: $(BUILD)/freedos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/freedos-test.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS tests/child.bat=TEST.BAT $(T_FILES)
	$(BOOT) $(BUILD)/freedos-test.img --timeout 120 --result RESULT.TXT

# Phase 5: NET, PING and FETCH, our own TCP/IP, with CLAUDE.COM the only shell. The
# 40 KB download needs a web server on the host's port 8766 serving big.txt.
net5test: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/freedos-test.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS tests/net5.bat=TEST.BAT
	$(BOOT) $(BUILD)/freedos-test.img --timeout 120 --result RESULT.TXT

# Phase 6: ASK, the conversation and NEW, through claude-p-shim on the host's port
# 8765 (started with SHIM_HOSTS=10.0.2.2). The key comes from SHIM_KEY, a path set in
# local.mk; it is copied onto the test image only, and never printed.
CLAUDE_FILES = image/common/CLAUDE.CFG=CLAUDE.CFG $(if $(SHIM_KEY),$(SHIM_KEY)=CLAUDE.KEY)

asktest: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/freedos-test.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS tests/ask.bat=TEST.BAT $(CLAUDE_FILES)
	$(BOOT) $(BUILD)/freedos-test.img --timeout 300 --result RESULT.TXT

rootnet: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/freedos-test.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS tests/net.bat=TEST.BAT
	$(BOOT) $(BUILD)/freedos-test.img --timeout 120 --result RESULT.TXT

# ---- MS-DOS 6.22: your own image, named in local.mk, never committed ----
# The image in use boots through its own MBR menu, so the tests press 1 ("Boot DOS").

MS_FILES = image/msdos/config.sys=CONFIG.SYS image/msdos/autoexec.bat=AUTOEXEC.BAT \
           $(NETFILES) $(PKG)/FDAPM.COM=NET/FDAPM.COM $(SHELL_COM)=CLAUDE.COM

$(BUILD)/msdos.img: $(MSDOS_BASE) $(PKG)/.done $(SHELL_COM) image/msdos/* image/common/NET/MTCP.CFG tools/mkimage.py
	@test -n "$(MSDOS_BASE)" || { echo "set MSDOS_BASE=/path/to/your/msdos622.img in local.mk"; exit 1; }
	$(MKIMAGE) $@ $(MSDOS_BASE) $(MS_FILES)

msdos: $(BUILD)/msdos.img

run-msdos: $(BUILD)/msdos.img
	@mkdir -p logs
	$(QEMU) -drive format=raw,file=$< -serial file:logs/console-$$(date +%Y%m%d-%H%M%S).log

nettest-msdos: $(BUILD)/msdos.img
	$(MKIMAGE) $(BUILD)/msdos-test.img $< tests/net.bat=TEST.BAT
	$(BOOT) $(BUILD)/msdos-test.img --timeout 120 --boot-wait 3 --keys '1' --result RESULT.TXT

shelltest-msdos: $(BUILD)/msdos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/msdos-test.img $< image/msdos/config-claude.sys=CONFIG.SYS $(T_FILES)
	$(BOOT) $(BUILD)/msdos-test.img --timeout 140 --boot-wait 3 \
	  --keys '1{wait}{wait}{wait}{wait}{wait}{wait}$(ROOT_KEYS)' --screen

cmdtest-msdos: $(BUILD)/msdos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/msdos-test.img $< tests/cmds.bat=TEST.BAT $(T_FILES)
	$(BOOT) $(BUILD)/msdos-test.img --timeout 120 --boot-wait 3 --keys '1' --result OURS.TXT REF.TXT OURS3.TXT REF3.TXT OURS4.TXT REF4.TXT

childtest-msdos: $(BUILD)/msdos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/msdos-test.img $< tests/child.bat=TEST.BAT $(T_FILES)
	$(BOOT) $(BUILD)/msdos-test.img --timeout 120 --boot-wait 3 --keys '1' --result RESULT.TXT

roottest-msdos: $(BUILD)/msdos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/msdos-test.img $< image/msdos/config-root.sys=CONFIG.SYS tests/child.bat=TEST.BAT $(T_FILES)
	$(BOOT) $(BUILD)/msdos-test.img --timeout 120 --boot-wait 3 --keys '1' --result RESULT.TXT

net5test-msdos: $(BUILD)/msdos.img
	$(MKIMAGE) $(BUILD)/msdos-test.img $< image/msdos/config-root.sys=CONFIG.SYS tests/net5.bat=TEST.BAT
	$(BOOT) $(BUILD)/msdos-test.img --timeout 120 --boot-wait 3 --keys '1' --result RESULT.TXT

# Typed at the prompt: a line that is not a command goes to Claude; a long answer wraps.
ASK_KEYS = what is the capital of france{ret}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}\
in about 70 words, what is a packet driver{ret}
asktype: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/freedos-test.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS $(CLAUDE_FILES)
	$(BOOT) $(BUILD)/freedos-test.img --timeout 60 --boot-wait 8 --keys '$(ASK_KEYS)' --screen

# Phase 7, typed at the prompt: Claude looks (DIR, no question asked), writes a file
# (allowed with Y), and tries to delete it (refused with N). A screen after each.
W20 = {wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}
W25 = {wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}{wait}
TOOL_KEYS = which files are in the root directory{ret}$(W25){screen}cls{ret}\
create a file NOTE.TXT that says hello from claude{ret}$(W20)y$(W25){screen}cls{ret}\
delete NOTE.TXT{ret}$(W20)n$(W25)
tooltest: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/freedos-test.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS $(CLAUDE_FILES)
	$(BOOT) $(BUILD)/freedos-test.img --timeout 200 --boot-wait 8 --keys '$(TOOL_KEYS)' --screen
	@echo "[tooltest] NOTE.TXT on the disk afterwards:"; mtype -i $(BUILD)/freedos-test.img@@32256 ::/NOTE.TXT || true

tooltest-msdos: $(BUILD)/msdos.img
	$(MKIMAGE) $(BUILD)/msdos-test.img $< image/msdos/config-root.sys=CONFIG.SYS $(CLAUDE_FILES)
	$(BOOT) $(BUILD)/msdos-test.img --timeout 200 --boot-wait 3 --keys '1{wait}{wait}{wait}{wait}{wait}{wait}$(TOOL_KEYS)' --screen
	@echo "[tooltest] NOTE.TXT on the disk afterwards:"; mtype -i $(BUILD)/msdos-test.img@@32256 ::/NOTE.TXT || true

asktest-msdos: $(BUILD)/msdos.img
	$(MKIMAGE) $(BUILD)/msdos-test.img $< image/msdos/config-root.sys=CONFIG.SYS tests/ask.bat=TEST.BAT $(CLAUDE_FILES)
	$(BOOT) $(BUILD)/msdos-test.img --timeout 300 --boot-wait 3 --keys '1' --result RESULT.TXT

rootnet-msdos: $(BUILD)/msdos.img
	$(MKIMAGE) $(BUILD)/msdos-test.img $< image/msdos/config-root.sys=CONFIG.SYS tests/net.bat=TEST.BAT
	$(BOOT) $(BUILD)/msdos-test.img --timeout 120 --boot-wait 3 --keys '1' --result RESULT.TXT

# ---- DOSBox-X: boots the same real-DOS images, NE2000 on its slirp network ----

DOSBOX_IMG ?= $(BUILD)/freedos.img

dbx: $(DOSBOX_IMG)
	cp $(DOSBOX_IMG) $(BUILD)/dbx.img
	$(call DBXCONF,$(BUILD)/dbx.img,$$PWD/$(BUILD)/dbx-console.log) > $(BUILD)/dbx.conf
	dosbox-x -conf $(BUILD)/dbx.conf

# Headless through SDL's dummy video driver; FDAPM POWEROFF at the end of the
# test closes DOSBox-X. The FreeDOS image only: the MS-DOS one waits at a boot menu.
nettest-dbx: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/dbx.img $< tests/net.bat=TEST.BAT
	$(call DBXCONF,$(BUILD)/dbx.img,$$PWD/$(BUILD)/dbx-console.log) > $(BUILD)/dbx.conf
	SDL_VIDEODRIVER=dummy perl -e 'alarm 150; exec @ARGV' dosbox-x -conf $(BUILD)/dbx.conf -silent > $(BUILD)/dbx.log 2>&1 || true
	mtype -i $(BUILD)/dbx.img@@32256 ::/RESULT.TXT | tr -d '\r'

cmdtest-dbx: $(BUILD)/freedos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/dbx.img $< tests/cmds.bat=TEST.BAT $(T_FILES)
	$(call DBXCONF,$(BUILD)/dbx.img,$$PWD/$(BUILD)/dbx-console.log) > $(BUILD)/dbx.conf
	SDL_VIDEODRIVER=dummy perl -e 'alarm 150; exec @ARGV' dosbox-x -conf $(BUILD)/dbx.conf -silent > $(BUILD)/dbx.log 2>&1 || true
	@for f in OURS.TXT REF.TXT OURS3.TXT REF3.TXT OURS4.TXT REF4.TXT; do echo "===== $$f"; mtype -i $(BUILD)/dbx.img@@32256 ::/$$f | tr -d '\r'; done

net5test-dbx: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/dbx.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS tests/net5.bat=TEST.BAT
	$(call DBXCONF,$(BUILD)/dbx.img,$$PWD/$(BUILD)/dbx-console.log) > $(BUILD)/dbx.conf
	SDL_VIDEODRIVER=dummy perl -e 'alarm 150; exec @ARGV' dosbox-x -conf $(BUILD)/dbx.conf -silent > $(BUILD)/dbx.log 2>&1 || true
	mtype -i $(BUILD)/dbx.img@@32256 ::/RESULT.TXT | tr -d '\r'

asktest-dbx: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/dbx.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS tests/ask.bat=TEST.BAT $(CLAUDE_FILES)
	$(call DBXCONF,$(BUILD)/dbx.img,$$PWD/$(BUILD)/dbx-console.log) > $(BUILD)/dbx.conf
	SDL_VIDEODRIVER=dummy perl -e 'alarm 300; exec @ARGV' dosbox-x -conf $(BUILD)/dbx.conf -silent > $(BUILD)/dbx.log 2>&1 || true
	mtype -i $(BUILD)/dbx.img@@32256 ::/RESULT.TXT | tr -d '\r'

childtest-dbx: $(BUILD)/freedos.img $(TESTPROGS)
	$(MKIMAGE) $(BUILD)/dbx.img $< tests/child.bat=TEST.BAT $(T_FILES)
	$(call DBXCONF,$(BUILD)/dbx.img,$$PWD/$(BUILD)/dbx-console.log) > $(BUILD)/dbx.conf
	SDL_VIDEODRIVER=dummy perl -e 'alarm 150; exec @ARGV' dosbox-x -conf $(BUILD)/dbx.conf -silent > $(BUILD)/dbx.log 2>&1 || true
	mtype -i $(BUILD)/dbx.img@@32256 ::/RESULT.TXT | tr -d '\r'

asktest-bochs: $(BUILD)/freedos.img $(BOCHS)
	$(MKIMAGE) $(BUILD)/bochs-test.img $< image/freedos/fdconfig-root.sys=FDCONFIG.SYS tests/ask.bat=TEST.BAT $(CLAUDE_FILES)
	$(call BOCHSRC,$(BUILD)/bochs-test.img,nogui,$$PWD/$(BUILD)/bochs-console.log) > $(BUILD)/bochs-test.rc
	perl -e 'alarm 240; exec @ARGV' $(BOCHS) -q -f $(BUILD)/bochs-test.rc < /dev/null > /dev/null 2>&1 || true
	mtype -i $(BUILD)/bochs-test.img@@32256 ::/RESULT.TXT | tr -d '\r'

clean:
	rm -rf $(BUILD)
