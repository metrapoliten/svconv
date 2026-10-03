# Тесты kernel_rom: make test [K=3]

ROOT := $(abspath ../..)

K ?= 5
export K

VERILOG_SOURCES     := $(ROOT)/rtl/core/kernel_rom.sv
COCOTB_TOPLEVEL     := kernel_rom
COCOTB_TEST_MODULES := test_kernel_rom
COMPILE_ARGS += -Pkernel_rom.K=$(K)
GEN_HEX := python3 $(ROOT)/model/gen_hex.py kernels --k $(K) -o kernels.hex

include $(ROOT)/tests/common/cocotb.mk
