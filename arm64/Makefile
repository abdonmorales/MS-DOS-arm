SHELL := /bin/bash
CROSS_COMPILE ?= aarch64-linux-gnu-
AS := $(CROSS_COMPILE)as
LD := $(CROSS_COMPILE)ld
OBJCOPY := $(CROSS_COMPILE)objcopy
NM := $(CROSS_COMPILE)nm
PYTHON ?= python3
BUILD ?= build

.PHONY: all image pi-image smoke clean
all: $(BUILD)/BOOTAA64.EFI
image: $(BUILD)/msdos-arm64.img
pi-image: $(BUILD)/msdos-arm64-pi3.img

FIRMWARE ?= /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
smoke: image
	$(PYTHON) tools/smoke.py $(BUILD)/msdos-arm64.img --firmware $(FIRMWARE) --log $(BUILD)/smoke.log

$(BUILD):
	mkdir -p $@

$(BUILD)/kernel.o: src/kernel.S | $(BUILD)
	$(AS) -march=armv8-a -g -o $@ $<

$(BUILD)/kernel.elf: $(BUILD)/kernel.o link.ld
	$(LD) -T link.ld --no-undefined -o $@ $<

$(BUILD)/kernel.bin: $(BUILD)/kernel.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/BOOTAA64.EFI: $(BUILD)/kernel.bin $(BUILD)/kernel.elf tools/pe.py
	$(PYTHON) tools/pe.py --nm $(NM) $(BUILD)/kernel.elf $< $@

$(BUILD)/msdos-arm64.img: $(BUILD)/BOOTAA64.EFI tools/image.py
	$(PYTHON) tools/image.py $< $@

$(BUILD)/msdos-arm64-pi3.img: $(BUILD)/BOOTAA64.EFI tools/pi_image.py
	$(PYTHON) tools/pi_image.py $< $@

clean:
	rm -rf -- $(BUILD)
