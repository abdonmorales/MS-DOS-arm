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

.PHONY: all image pi-image smoke validate snapshot clean
all: $(BUILD)/BOOTAA64.EFI $(BUILD)/NATIVE.EXE
image: $(BUILD)/msdos-arm64.img
pi-image: $(BUILD)/msdos-arm64-pi3.img

FIRMWARE ?= /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
PI_FIRMWARE ?=
smoke: image
	$(PYTHON) tools/smoke.py $(BUILD)/msdos-arm64.img --firmware $(FIRMWARE) --log $(BUILD)/smoke.log

validate: image pi-image
	$(PYTHON) tools/validate.py --build $(BUILD) --firmware $(FIRMWARE)

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

$(BUILD)/native.o: programs/native.S | $(BUILD)
	$(AS) -march=armv8-a -g -o $@ $<

$(BUILD)/native.elf: $(BUILD)/native.o link.ld
	$(LD) -T link.ld --no-undefined -o $@ $<

$(BUILD)/native.bin: $(BUILD)/native.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/NATIVE.EXE: $(BUILD)/native.bin $(BUILD)/native.elf tools/pe.py
	$(PYTHON) tools/pe.py --nm $(NM) $(BUILD)/native.elf $< $@

$(BUILD)/msdos-arm64.img: $(BUILD)/BOOTAA64.EFI $(BUILD)/NATIVE.EXE $(FIXTURES) tools/image.py
	$(PYTHON) tools/image.py $< $@

$(BUILD)/msdos-arm64-pi3.img: $(BUILD)/BOOTAA64.EFI $(BUILD)/NATIVE.EXE $(FIXTURES) tools/pi_image.py
	$(PYTHON) tools/pi_image.py $< $@ --replace-generated $(if $(PI_FIRMWARE),--firmware "$(PI_FIRMWARE)")

clean:
	rm -rf -- $(BUILD)
