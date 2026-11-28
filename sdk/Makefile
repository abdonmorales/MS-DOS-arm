# SPDX-License-Identifier: MIT
# ARM DOS C SDK: libarmdos.a, crt0.o and the example programs.
#   make            build everything into $(BUILD) (default ../build/sdk)
# See sdk/README.md, "Building your own program".
CROSS_COMPILE ?= aarch64-linux-gnu-
CC := $(CROSS_COMPILE)gcc
AR := $(CROSS_COMPILE)ar
PYTHON ?= python3
SDK := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILD ?= $(abspath $(SDK)/../build/sdk)

# Only GCC's own freestanding headers (stddef.h, stdint.h, stdarg.h,
# limits.h, stdbool.h) plus ours: never the host C library's.
GCC_INCLUDE := $(shell $(CC) -print-file-name=include)
CFLAGS ?= -O2 -g -Wall -Wextra
SDK_CFLAGS := -std=gnu11 -ffreestanding -fno-builtin -nostdinc \
	-isystem $(GCC_INCLUDE) -I$(SDK)/include \
	-fno-pic -fno-pie -mcmodel=small -mgeneral-regs-only -mno-outline-atomics \
	-fno-stack-protector -fno-asynchronous-unwind-tables -fno-unwind-tables \
	-fno-tree-loop-distribute-patterns -ffunction-sections -fdata-sections
SDK_LDFLAGS := -nostdlib -static -no-pie -Wl,-T,$(SDK)/link.ld -Wl,--emit-relocs \
	-Wl,--gc-sections -Wl,--build-id=none -Wl,--no-warn-rwx-segments

LIB_SOURCES := $(wildcard $(SDK)/lib/*.c) $(SDK)/crt/start.c
LIB_OBJECTS := $(patsubst $(SDK)/%.c,$(BUILD)/obj/%.o,$(LIB_SOURCES))
HEADERS := $(wildcard $(SDK)/include/*.h)
EXAMPLES := $(patsubst $(SDK)/examples/%.c,%,$(wildcard $(SDK)/examples/*.c))
TESTS := $(patsubst $(SDK)/tests/%.c,%,$(wildcard $(SDK)/tests/*.c))
upper = $(shell echo $(1) | tr a-z A-Z)
PROGRAMS := $(foreach p,$(EXAMPLES) $(TESTS),$(BUILD)/$(call upper,$(p)).EXE)

.PHONY: all lib clean
.SECONDARY:
all: lib $(PROGRAMS)
lib: $(BUILD)/libarmdos.a $(BUILD)/crt0.o

$(BUILD)/crt0.o: $(SDK)/crt/crt0.S
	@mkdir -p $(dir $@)
	$(CC) $(SDK_CFLAGS) -c -o $@ $<

$(BUILD)/obj/%.o: $(SDK)/%.c $(HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(SDK_CFLAGS) $(CFLAGS) -c -o $@ $<

$(BUILD)/libarmdos.a: $(LIB_OBJECTS)
	@rm -f $@
	$(AR) rcs $@ $^

# A program: crt0.o first, its objects, then the library.
$(BUILD)/%.elf: $(BUILD)/crt0.o $(BUILD)/libarmdos.a $(SDK)/link.ld
	$(CC) $(SDK_LDFLAGS) -o $@ $(BUILD)/crt0.o \
		$(filter-out $(BUILD)/crt0.o,$(filter %.o,$^)) $(BUILD)/libarmdos.a

define program_rule
$(BUILD)/$(2).elf: $(BUILD)/obj/$(1)/$(2).o
$(BUILD)/$(call upper,$(2)).EXE: $(BUILD)/$(2).elf $(SDK)/tools/elf2pe.py
	$$(PYTHON) $(SDK)/tools/elf2pe.py $$< $$@
endef
$(foreach p,$(EXAMPLES),$(eval $(call program_rule,examples,$(p))))
$(foreach p,$(TESTS),$(eval $(call program_rule,tests,$(p))))

clean:
	rm -rf -- $(BUILD)/obj $(BUILD)/*.elf $(BUILD)/*.EXE $(BUILD)/libarmdos.a $(BUILD)/crt0.o
