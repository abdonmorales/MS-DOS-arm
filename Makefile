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
.PHONY: all payloads image pi-image unit smoke smoke-firmware check validate snapshot fat-test pi-test iso iso-test clean
all: $(BUILD)/BOOTAA64.EFI payloads
image: $(BUILD)/msdos-arm64.img
iso: $(BUILD)/armdos.iso
pi-image: $(BUILD)/msdos-arm64-pi3.img

FIRMWARE ?= /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
PI_FIRMWARE ?=
unit: $(BUILD)/kernel.elf $(BUILD)/kernel.bin $(BUILD)/NATIVE.EXE
	$(PYTHON) tools/unit.py --build $(BUILD) --nm $(NM)

smoke: image
	$(PYTHON) tools/smoke.py $(BUILD)/msdos-arm64.img --firmware $(FIRMWARE) --log $(BUILD)/smoke.log

# Same checks with ACPI hidden, so the kernel must keep using UEFI services.
smoke-firmware: image
	$(PYTHON) tools/smoke.py $(BUILD)/msdos-arm64.img --firmware $(FIRMWARE) --mode firmware --log $(BUILD)/smoke-firmware.log

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

snapshot: validate iso-test
	$(PYTHON) tools/snapshot.py --build $(BUILD) --output images

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
$(BUILD)/armdos.iso: $(BUILD)/msdos-arm64.img tools/iso.py
	$(PYTHON) tools/iso.py $< $@
iso-test: $(BUILD)/armdos.iso
	$(PYTHON) tools/iso_test.py $< --firmware $(FIRMWARE) --image $(BUILD)/msdos-arm64.img

$(BUILD)/msdos-arm64-pi3.img: $(BUILD)/BOOTAA64.EFI $(PAYLOADS) $(FIXTURES) tools/pi_image.py
	$(PYTHON) tools/pi_image.py $< $@ --replace-generated $(if $(PI_FIRMWARE),--firmware "$(PI_FIRMWARE)")

clean:
	rm -rf -- $(BUILD)

# System fuzzing: malformed PE32+ images through the loader (Unicorn), ARM
# BASIC programs and COMMAND lines (QEMU). FUZZ_SECONDS bounds the run and
# FUZZ_SEED makes it reproducible; findings go to $(BUILD)/fuzz-crashes/.
FUZZ_SECONDS ?= 60
FUZZ_SEED ?=
.PHONY: fuzz-sys
fuzz-sys: $(BUILD)/kernel.elf $(BUILD)/kernel.bin image
	FUZZ_SECONDS=$(FUZZ_SECONDS) FUZZ_SEED=$(FUZZ_SEED) $(PYTHON) tools/fuzz_sys.py \
		--build $(BUILD) --nm $(NM) --firmware $(FIRMWARE)
