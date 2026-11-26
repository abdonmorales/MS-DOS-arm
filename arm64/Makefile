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
.PHONY: all payloads image pi-image unit smoke smoke-firmware check validate snapshot fat-test clean
all: $(BUILD)/BOOTAA64.EFI payloads
image: $(BUILD)/msdos-arm64.img
payloads: $(PAYLOADS)
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

check: unit
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

snapshot: validate
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

# COUNTRY.SYS is data: the DOS 4.0 file assembled from MKCNTRY.ASM.
$(BUILD)/COUNTRY.SYS: ../v4.0/src/DEV/COUNTRY/MKCNTRY.ASM ../v4.0/src/DEV/COUNTRY/MKCNTRY.INC tools/mkcntry.py | $(BUILD)
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

$(BUILD)/msdos-arm64-pi3.img: $(BUILD)/BOOTAA64.EFI $(PAYLOADS) $(FIXTURES) tools/pi_image.py
	$(PYTHON) tools/pi_image.py $< $@ --replace-generated $(if $(PI_FIRMWARE),--firmware "$(PI_FIRMWARE)")

clean:
	rm -rf -- $(BUILD)
