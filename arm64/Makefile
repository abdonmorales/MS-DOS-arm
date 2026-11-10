# MS-DOS for AArch64 -- top level build.
#
#   make            kernel + all programs + disk image
#   make run        boot in QEMU (serial console on stdio, Ctrl-A X quits)
#   make test       scripted boot tests (tests/run-tests.sh)
#   make clean
#
# Layout conventions (the build discovers sources by wildcard):
#   bios/*.S bios/*.c  dos/*.c   -> build/kernel.elf   (linked with bios/kernel.ld)
#   lib/crt0.S                   -> build/u/lib/crt0.o (first object of every program)
#   lib/*.c lib/*.S (not crt0)   -> build/lib/libdos.a
#   cmd/<name>/*.c               -> build/bin/<NAME>.COM  (linked with lib/user.ld)
#   disk/*                       -> copied verbatim into the root of the disk image

CROSS   ?= --target=aarch64-none-elf
CC      := clang
LD      := ld.lld
AR      := llvm-ar
OBJCOPY := llvm-objcopy
PYTHON  ?= python3
QEMU    ?= qemu-system-aarch64

B := build

COMMON  := $(CROSS) -ffreestanding -nostdlib -nostdinc -mgeneral-regs-only -mstrict-align \
           -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables \
           -Wall -Wextra -Wno-unused-parameter -O2 -g
# clang's own freestanding headers (stdint.h, stddef.h, stdarg.h...)
RESDIR  := $(shell $(CC) -print-resource-dir)
SYSINC  := -isystem $(RESDIR)/include

KCFLAGS := $(COMMON) $(SYSINC) -Iinclude -Ibios -Idos -DDOS_KERNEL -mcmodel=small -fno-pic
UCFLAGS := $(COMMON) $(SYSINC) -Iinclude -Ilib/include -fPIE -mcmodel=tiny -fno-plt \
           -fvisibility=hidden

# ---------------------------------------------------------------- kernel
KSRC_S := $(wildcard bios/*.S)
KSRC_C := $(wildcard bios/*.c) $(wildcard dos/*.c)
KOBJ   := $(patsubst %.S,$(B)/k/%.o,$(KSRC_S)) $(patsubst %.c,$(B)/k/%.o,$(KSRC_C))

# ---------------------------------------------------------------- library
LSRC_S := $(filter-out lib/crt0.S,$(wildcard lib/*.S))
LSRC_C := $(wildcard lib/*.c)
LOBJ   := $(patsubst %.S,$(B)/u/%.o,$(LSRC_S)) $(patsubst %.c,$(B)/u/%.o,$(LSRC_C))
CRT0   := $(B)/u/lib/crt0.o
LIBDOS := $(B)/lib/libdos.a

# ---------------------------------------------------------------- programs
upper   = $(shell echo $(1) | tr a-z A-Z)
CMDS   := $(notdir $(patsubst %/,%,$(wildcard cmd/*/)))
BINS   := $(foreach c,$(CMDS),$(B)/bin/$(call upper,$(c)).COM)

IMG    := $(B)/dos.img

.PHONY: all kernel programs image run test clean
all: kernel programs image
kernel: $(B)/kernel.elf
programs: $(BINS)
image: $(IMG)

$(B)/k/%.o: %.S
	@mkdir -p $(@D)
	$(CC) $(KCFLAGS) -D__ASSEMBLY__ -c $< -o $@
$(B)/k/%.o: %.c
	@mkdir -p $(@D)
	$(CC) $(KCFLAGS) -MMD -c $< -o $@
$(B)/kernel.elf: $(KOBJ) bios/kernel.ld
	$(LD) -nostdlib -static -T bios/kernel.ld -Map=$(B)/kernel.map -o $@ $(KOBJ)

$(B)/u/%.o: %.S
	@mkdir -p $(@D)
	$(CC) $(UCFLAGS) -D__ASSEMBLY__ -c $< -o $@
$(B)/u/%.o: %.c
	@mkdir -p $(@D)
	$(CC) $(UCFLAGS) -MMD -c $< -o $@
$(LIBDOS): $(LOBJ)
	@mkdir -p $(@D)
	$(AR) rcs $@.tmp $(LOBJ) && mv -f $@.tmp $@

# one rule set per program directory
define PROGRAM
$(1)_OBJ := $$(patsubst %.c,$(B)/u/%.o,$$(wildcard cmd/$(1)/*.c))
$(B)/bin/$(call upper,$(1)).elf: $$($(1)_OBJ) $(CRT0) $(LIBDOS) lib/user.ld
	@mkdir -p $$(@D)
	$(LD) -nostdlib -static -pie --no-dynamic-linker -z norelro -z notext \
	      -T lib/user.ld -o $$@ $(CRT0) $$($(1)_OBJ) $(LIBDOS)
$(B)/bin/$(call upper,$(1)).COM: $(B)/bin/$(call upper,$(1)).elf
	$(OBJCOPY) -O binary $$< $$@
endef
$(foreach c,$(CMDS),$(eval $(call PROGRAM,$(c))))

$(IMG): $(BINS) $(wildcard disk/*) tools/mkdisk.py
	$(PYTHON) tools/mkdisk.py -o $@ $(BINS) $(wildcard disk/*)

QEMUFLAGS := -M virt -cpu cortex-a53 -m 128M -nographic -no-reboot \
             -kernel $(B)/kernel.elf \
             -drive if=none,file=$(IMG),format=raw,id=hd0 \
             -device virtio-blk-device,drive=hd0

run: all
	$(QEMU) $(QEMUFLAGS)
test: all
	sh tests/run-tests.sh

clean:
	rm -rf build

-include $(shell find $(B) -name '*.d' 2>/dev/null)
