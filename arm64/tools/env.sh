#!/usr/bin/env bash
# Optional activation for the tools installed during this cloud task.
# Source this file; system-installed cross tools do not need it.
export PATH="/workspace/arm-toolchain/runtime/usr/bin:/workspace/arm-toolchain/runtime/usr/sbin:$PATH"
export LD_LIBRARY_PATH="/workspace/arm-toolchain/runtime/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
