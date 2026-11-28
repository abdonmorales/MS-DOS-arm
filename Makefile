SHELL := /bin/bash
CROSS_COMPILE ?= aarch64-linux-gnu-
AS := $(CROSS_COMPILE)as
LD := $(CROSS_COMPILE)ld
OBJCOPY := $(CROSS_COMPILE)objcopy
NM := $(CROSS_COMPILE)nm
PYTHON ?= python3
BUILD ?= build
SOURCES := $(wildcard src/*.S)
FIXTURES := $(wildcard fixtures/*)

.SECONDARY:
.PHONY: all payloads image pi-image unit smoke smoke-firmware smoke-el2 check validate snapshot fat-test pi-test iso iso-test rom-generic rom-pi rom-test clean
all: $(BUILD)/BOOTAA64.EFI payloads
image: $(BUILD)/msdos-arm64.img
iso: $(BUILD)/armdos.iso
pi-image: $(BUILD)/msdos-arm64-pi3.img

FIRMWARE ?= /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
PI_FIRMWARE ?=
unit: $(BUILD)/kernel.elf $(BUILD)/kernel.bin
	$(PYTHON) tools/unit.py --build $(BUILD) --nm $(NM)

smoke: image
	$(PYTHON) tools/smoke.py $(BUILD)/msdos-arm64.img --firmware $(FIRMWARE) --log $(BUILD)/smoke.log

# Same checks with ACPI hidden, so the kernel must keep using UEFI services.
smoke-firmware: image
	$(PYTHON) tools/smoke.py $(BUILD)/msdos-arm64.img --firmware $(FIRMWARE) --mode firmware --log $(BUILD)/smoke-firmware.log

# Native mode entered at EL2 (as on a Raspberry Pi): the kernel drops to EL1.
smoke-el2: image
	$(PYTHON) tools/smoke.py $(BUILD)/msdos-arm64.img --firmware $(FIRMWARE) --el2 --log $(BUILD)/smoke-el2.log

check: unit pi-test
	$(MAKE) smoke

validate: image pi-image
	$(PYTHON) tools/validate.py --build $(BUILD) --firmware $(FIRMWARE)

# Host stress test of src/fat.S (needs an AArch64 Linux cross compiler and
# qemu-user): FAT12/16/32 images checked with fsck.fat and mtools.
HOST_CC ?= aarch64-linux-gnu-gcc
QEMU_USER ?= qemu-aarch64
fat-test: $(BUILD)/fat_host
	$(PYTHON) tools/fat_test.py --host $(BUILD)/fat_host --qemu $(QEMU_USER)

$(BUILD)/fat_host: tests/fat_host.c tests/fat_host_glue.S src/fat.S | $(BUILD)
	$(HOST_CC) -static -O1 -Wall -Wa,-I. -o $@ tests/fat_host.c tests/fat_host_glue.S

# Release assets (not committed): see .github/workflows/release.yml.
SNAPSHOT_DIR ?= $(BUILD)/release
snapshot: validate iso-test
	$(PYTHON) tools/snapshot.py --build $(BUILD) --output $(SNAPSHOT_DIR)

$(BUILD):
	mkdir -p $@

$(BUILD)/kernel.o: $(SOURCES) | $(BUILD)
	$(AS) -march=armv8-a -g -o $@ src/kernel.S

$(BUILD)/kernel.elf: $(BUILD)/kernel.o link.ld
	$(LD) -T link.ld --no-undefined -o $@ $<

$(BUILD)/kernel.bin: $(BUILD)/kernel.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/BOOTAA64.EFI: $(BUILD)/kernel.bin $(BUILD)/kernel.elf tools/pe.py
	$(PYTHON) tools/pe.py --nm $(NM) $(BUILD)/kernel.elf $< $@

# Separately linked native programs (programs/*.S -> NAME.EXE) and
# installable drivers (drivers/*.S -> NAME.SYS), all PE32+ images.
upper = $(shell echo $(1) | tr a-z A-Z)
PROGRAM_NAMES := $(patsubst programs/%.S,%,$(wildcard programs/*.S))
DRIVER_NAMES := $(patsubst drivers/%.S,%,$(wildcard drivers/*.S))
PAYLOADS := $(foreach p,$(PROGRAM_NAMES),$(BUILD)/$(call upper,$(p)).EXE) \
	$(foreach p,$(DRIVER_NAMES),$(BUILD)/$(call upper,$(p)).SYS) $(BUILD)/COUNTRY.SYS
# After PAYLOADS is set: a rule's prerequisites expand when it is read.
payloads: $(PAYLOADS)

# The Pi 3 SD card and UART drivers, bare metal on QEMU raspi3b.
pi-test: $(BUILD)/sdtest.bin $(BUILD)/msdos-arm64.img
	$(PYTHON) tools/pi_test.py $(BUILD)/sdtest.bin $(BUILD)/msdos-arm64.img

$(BUILD)/sdtest.bin: tests/pi/sdtest.S tests/pi/link.ld src/sdhci.S | $(BUILD)
	$(AS) -march=armv8-a -o $(BUILD)/sdtest.o $<
	$(LD) -T tests/pi/link.ld --no-warn-rwx-segments -o $(BUILD)/sdtest.elf $(BUILD)/sdtest.o
	$(OBJCOPY) -O binary $(BUILD)/sdtest.elf $@

# COUNTRY.SYS is data: the DOS 4.0 file assembled from the data segment of
# MKCNTRY.ASM (data/country).
$(BUILD)/COUNTRY.SYS: data/country/MKCNTRY.ASM data/country/MKCNTRY.INC data/country/COPYRIGH.INC tools/mkcntry.py | $(BUILD)
	$(PYTHON) tools/mkcntry.py $< $@

$(BUILD)/%.o: programs/%.S programs/lib.inc programs/fatlib.inc programs/cds.inc programs/sysxfer.inc programs/diskdrv.inc programs/backup.inc | $(BUILD)
	$(AS) -march=armv8-a -g -I programs -o $@ $<

$(BUILD)/%.o: drivers/%.S drivers/ramdisk.inc | $(BUILD)
	$(AS) -march=armv8-a -g -I programs -o $@ $<

$(BUILD)/%.elf: $(BUILD)/%.o link.ld
	$(LD) -T link.ld --no-undefined -o $@ $<

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@

define payload_rule
$(BUILD)/$(2): $(BUILD)/$(1).bin $(BUILD)/$(1).elf tools/pe.py
	$$(PYTHON) tools/pe.py --nm $$(NM) $(BUILD)/$(1).elf $$< $$@
endef
$(foreach p,$(PROGRAM_NAMES),$(eval $(call payload_rule,$(p),$(call upper,$(p)).EXE)))
$(foreach p,$(DRIVER_NAMES),$(eval $(call payload_rule,$(p),$(call upper,$(p)).SYS)))

$(BUILD)/msdos-arm64.img: $(BUILD)/BOOTAA64.EFI $(PAYLOADS) $(FIXTURES) tools/image.py
	$(PYTHON) tools/image.py $< $@

# Live ISO (UEFI El Torito) for VMs; needs xorriso. iso-test boots it as a CD.
$(BUILD)/armdos.iso: $(BUILD)/msdos-arm64.img tools/iso.py tools/release.py
	$(PYTHON) tools/iso.py $< $@
iso-test: $(BUILD)/armdos.iso
	$(PYTHON) tools/iso_test.py $< --firmware $(FIRMWARE) --image $(BUILD)/msdos-arm64.img

$(BUILD)/msdos-arm64-pi3.img: $(BUILD)/BOOTAA64.EFI $(PAYLOADS) $(FIXTURES) tools/pi_image.py
	$(PYTHON) tools/pi_image.py $< $@ --replace-generated $(if $(PI_FIRMWARE),--firmware "$(PI_FIRMWARE)")

# ROM builds: one EFI application, ARMDOS.EFI, that carries a read-only
# drive A: (tools/romdisk.py) and needs no disk. rom-generic packages it for
# U-Boot (a FIT image and a NOR flash image) and any UEFI board; rom-pi puts
# it on Raspberry Pi 3 and 4 SD/USB images with the pftf UEFI firmware.
# GENERIC_NATIVE / PI_NATIVE = 1 put \NATIVE.ON on the ROM disk, so the
# kernel leaves the firmware when it finds the console UART.
GENERIC_NATIVE ?= 1
PI_NATIVE ?= 0
PI3_FIRMWARE ?= $(PI_FIRMWARE)
PI4_FIRMWARE ?=
UBOOT ?= /usr/lib/u-boot/qemu_arm64/u-boot.bin
MKIMAGE ?= mkimage
ROM_GENERIC := $(BUILD)/rom-generic
ROM_PI := $(BUILD)/rom-pi
rom-generic: $(ROM_GENERIC)/ARMDOS.EFI $(ROM_GENERIC)/armdos-rom.itb $(ROM_GENERIC)/armdos-rom-flash.bin
rom-pi: $(ROM_PI)/armdos-rom-pi3.img $(ROM_PI)/armdos-rom-pi4.img

# native.cfg holds the NATIVE setting a ROM build was made with; it is
# rewritten (and the ROM disk rebuilt) only when the setting changes.
GENERIC_NATIVE_FLAG := $(if $(filter 1,$(GENERIC_NATIVE)),--native)
PI_NATIVE_FLAG := $(if $(filter 1,$(PI_NATIVE)),--native)
$(ROM_GENERIC)/native.cfg: FORCE
	@mkdir -p $(@D); echo '$(GENERIC_NATIVE_FLAG)' | cmp -s - $@ || echo '$(GENERIC_NATIVE_FLAG)' > $@
$(ROM_PI)/native.cfg: FORCE
	@mkdir -p $(@D); echo '$(PI_NATIVE_FLAG)' | cmp -s - $@ || echo '$(PI_NATIVE_FLAG)' > $@
FORCE:
.PHONY: FORCE

$(BUILD)/rom-%/armdos-romdisk.img: $(BUILD)/msdos-arm64.img $(BUILD)/rom-%/native.cfg tools/romdisk.py tools/release.py
	$(PYTHON) tools/romdisk.py $< $@ --target $* $(shell cat $(@D)/native.cfg 2>/dev/null)

# rom-check: the generic build plus test programs (tests/rom/*.S), for
# rom-test only.
ROM_CHECK := $(BUILD)/rom-check
ROM_CHECK_PROGRAMS := $(patsubst tests/rom/%.S,$(ROM_CHECK)/%.EXE,$(wildcard tests/rom/*.S))
$(ROM_CHECK)/%.o: tests/rom/%.S programs/lib.inc programs/fatlib.inc
	@mkdir -p $(@D)
	$(AS) -march=armv8-a -g -I programs -o $@ $<
$(ROM_CHECK)/%.EXE: $(ROM_CHECK)/%.o link.ld tools/pe.py
	$(LD) -T link.ld --no-undefined -o $(ROM_CHECK)/$*.elf $<
	$(OBJCOPY) -O binary $(ROM_CHECK)/$*.elf $(ROM_CHECK)/$*.bin
	$(PYTHON) tools/pe.py --nm $(NM) $(ROM_CHECK)/$*.elf $(ROM_CHECK)/$*.bin $@
$(ROM_CHECK)/armdos-romdisk.img: $(BUILD)/msdos-arm64.img $(ROM_CHECK_PROGRAMS) tools/romdisk.py tools/release.py
	$(PYTHON) tools/romdisk.py $< $@ --target check --native --extra $(ROM_CHECK_PROGRAMS)

# kernel.S embeds armdos-romdisk.img, found through -I $(@D).
$(BUILD)/rom-%/kernel.o: $(BUILD)/rom-%/armdos-romdisk.img $(SOURCES)
	$(AS) -march=armv8-a -g --defsym ROM_BUILD=1 -I $(@D) -o $@ src/kernel.S
$(BUILD)/rom-%/kernel.elf: $(BUILD)/rom-%/kernel.o link.ld
	$(LD) -T link.ld --no-undefined -o $@ $<
$(BUILD)/rom-%/kernel.bin: $(BUILD)/rom-%/kernel.elf
	$(OBJCOPY) -O binary $< $@
$(BUILD)/rom-%/ARMDOS.EFI: $(BUILD)/rom-%/kernel.bin $(BUILD)/rom-%/kernel.elf tools/pe.py
	$(PYTHON) tools/pe.py --nm $(NM) $(@D)/kernel.elf $< $@

$(ROM_GENERIC)/armdos-rom.itb $(ROM_GENERIC)/armdos-rom-flash.bin &: $(ROM_GENERIC)/ARMDOS.EFI tools/rom_generic.py
	$(PYTHON) tools/rom_generic.py $< --mkimage $(MKIMAGE) --fit $(ROM_GENERIC)/armdos-rom.itb --flash $(ROM_GENERIC)/armdos-rom-flash.bin

$(ROM_PI)/armdos-rom-pi%.img: $(ROM_PI)/ARMDOS.EFI tools/rom_pi.py
	$(PYTHON) tools/rom_pi.py $< $@ --model $* $(if $(PI$*_FIRMWARE),--firmware "$(PI$*_FIRMWARE)")

# Boots the ROM builds in QEMU virt: EDK2 (network boot, native and
# firmware mode, device tree), U-Boot from NOR flash, and the Pi image's
# kernel; checks the Pi images' contents.
rom-test: rom-generic rom-pi $(ROM_CHECK)/ARMDOS.EFI
	$(PYTHON) tools/rom_test.py --build $(BUILD) --firmware $(FIRMWARE) --uboot $(UBOOT) \
		$(if $(GENERIC_NATIVE_FLAG),,--generic-firmware-mode) $(if $(PI_NATIVE_FLAG),--pi-native)

clean:
	rm -rf -- $(BUILD)

# Fuzz src/fat.S with corrupt FAT12/16/32 images (tools/fuzz_fat.py).
# Findings are minimised into build/fuzz-crashes/fat/.
FUZZ_SECONDS ?= 60
FUZZ_SEED ?= 1
.PHONY: fuzz-fat
fuzz-fat: $(BUILD)/fat_host
	$(PYTHON) tools/fuzz_fat.py --host $(BUILD)/fat_host --qemu $(QEMU_USER) fuzz --seconds $(FUZZ_SECONDS) --seed $(FUZZ_SEED)

# Regenerated images for every bug the fuzzer found; also run by fat-test.
.PHONY: fuzz-fat-regress
fuzz-fat-regress: $(BUILD)/fat_host
	$(PYTHON) tools/fuzz_fat.py --host $(BUILD)/fat_host --qemu $(QEMU_USER) regress
fat-test: fuzz-fat-regress
