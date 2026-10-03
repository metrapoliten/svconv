# Тесты conv_pipeline: make test [WIDTH=160 HEIGHT=120]

ROOT := $(abspath ../..)

WIDTH  ?= 16
HEIGHT ?= 12
K      ?= 5
export WIDTH HEIGHT K

VERILOG_SOURCES     := $(addprefix $(ROOT)/rtl/core/, \
                         sdp_ram.sv conv2d_stage.sv kernel_rom.sv conv_pipeline.sv)
COCOTB_TOPLEVEL     := conv_pipeline
COCOTB_TEST_MODULES := test_conv_pipeline
COMPILE_ARGS += -Pconv_pipeline.Width=$(WIDTH) -Pconv_pipeline.Height=$(HEIGHT) \
                -Pconv_pipeline.K=$(K)
GEN_HEX := python3 $(ROOT)/model/gen_hex.py kernels --k $(K) -o kernels.hex

include $(ROOT)/tests/common/cocotb.mk
