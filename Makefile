## dos-claude-shell build. Needs nasm, qemu-system-i386, mtools and python3.
##
##   make              build/claude.com, the shell
##   make fetch        download FreeDOS 1.4 Lite, the NE2000 packet driver and mTCP (hash-checked)
##   make freedos      build/freedos.img: FreeDOS with FreeCOM, the network, and CLAUDE.COM beside it
##   make run          boot that in a QEMU window; the console is kept in logs/
##   make nettest      headless: DHCP, ping the host, TCP to the shim, printed from C:\RESULT.TXT
##   make shelltest    headless: boot with SHELL=\CLAUDE.COM, type a line, print the screen
##   make msdos ...    the same on a copy of your own MS-DOS 6.22 image (msdos, run-msdos,
##                     nettest-msdos, shelltest-msdos); set MSDOS_BASE in local.mk
##   make dbx          boot FreeDOS in a DOSBox-X window (DOSBOX_IMG=build/msdos.img for MS-DOS)
##   make nettest-dbx  the network test in DOSBox-X, headless
##
## Every image is a copy: the FreeDOS download and your MS-DOS image are never written.

-include local.mk

BUILD   := build
PKG     := $(BUILD)/pkg
FD_BASE := $(BUILD)/fd14lite.img
SHELL_COM := $(BUILD)/claude.com
MKIMAGE := python3 tools/mkimage.py
BOOT    := python3 tools/boot.py

QEMU    := qemu-system-i386 -m 16 -rtc base=localtime \
           -netdev user,id=n0 -device ne2k_isa,netdev=n0,iobase=0x300,irq=10 \
           -object filter-dump,id=d0,netdev=n0,file=$(BUILD)/net.pcap

NETFILES = $(PKG)/DRIVERS/CRYNWR/NE2000.COM=NET/NE2000.COM \
           image/common/NET/MTCP.CFG=NET/MTCP.CFG \
           $(PKG)/NET/mTCP/dhcp.exe=NET/DHCP.EXE \
           $(PKG)/NET/mTCP/ping.exe=NET/PING.EXE \
           $(PKG)/NET/mTCP/htget.exe=NET/HTGET.EXE \
           $(PKG)/NET/mTCP/nc.exe=NET/NC.EXE

.PHONY: all fetch freedos run nettest shelltest msdos run-msdos nettest-msdos shelltest-msdos \
        dbx nettest-dbx clean

all: $(SHELL_COM)

$(BUILD):
	mkdir -p $(BUILD)

$(SHELL_COM): src/claude.asm | $(BUILD)
	nasm -f bin -o $@ $<

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

run: $(BUILD)/freedos.img
	@mkdir -p logs
	$(QEMU) -drive format=raw,file=$< -serial file:logs/console-$$(date +%Y%m%d-%H%M%S).log

# The test images are made fresh for every run, since a run writes to its disk.
nettest: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/freedos-test.img $< tests/net.bat=TEST.BAT
	$(BOOT) $(BUILD)/freedos-test.img --timeout 120 --result RESULT.TXT

shelltest: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/freedos-test.img $< image/freedos/fdconfig-claude.sys=FDCONFIG.SYS
	$(BOOT) $(BUILD)/freedos-test.img --timeout 14 --keys 'hello from the keyboard{ret}' --screen

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

shelltest-msdos: $(BUILD)/msdos.img
	$(MKIMAGE) $(BUILD)/msdos-test.img $< image/msdos/config-claude.sys=CONFIG.SYS
	$(BOOT) $(BUILD)/msdos-test.img --timeout 20 --boot-wait 3 \
	  --keys '1{wait}{wait}{wait}{wait}{wait}{wait}hello from the keyboard{ret}' --screen

# ---- DOSBox-X: boots the same real-DOS images, NE2000 on its slirp network ----

DOSBOX_IMG ?= $(BUILD)/freedos.img

dbx: $(DOSBOX_IMG)
	cp $(DOSBOX_IMG) $(BUILD)/dbx.img
	sed "s#%IMG%#$$PWD/$(BUILD)/dbx.img#" image/dosbox-x/boot.conf > $(BUILD)/dbx.conf
	dosbox-x -conf $(BUILD)/dbx.conf

# Headless through SDL's dummy video driver; FDAPM POWEROFF at the end of the
# test closes DOSBox-X. The FreeDOS image only: the MS-DOS one waits at a boot menu.
nettest-dbx: $(BUILD)/freedos.img
	$(MKIMAGE) $(BUILD)/dbx.img $< tests/net.bat=TEST.BAT
	sed "s#%IMG%#$$PWD/$(BUILD)/dbx.img#" image/dosbox-x/boot.conf > $(BUILD)/dbx.conf
	SDL_VIDEODRIVER=dummy perl -e 'alarm 150; exec @ARGV' dosbox-x -conf $(BUILD)/dbx.conf -silent > $(BUILD)/dbx.log 2>&1 || true
	mtype -i $(BUILD)/dbx.img@@32256 ::/RESULT.TXT | tr -d '\r'

clean:
	rm -rf $(BUILD)
