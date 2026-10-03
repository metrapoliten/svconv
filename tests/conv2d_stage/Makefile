# Тесты conv2d_stage.
#
#   make test                          — кадр 16×12, окно 5×5 (быстро)
#   make test WIDTH=160 HEIGHT=120     — рабочий размер кадра
#   make test K=3                      — окно 3×3

ROOT := $(abspath ../..)

WIDTH  ?= 16
HEIGHT ?= 12
K      ?= 5
export WIDTH HEIGHT K

VERILOG_SOURCES     := $(ROOT)/rtl/core/sdp_ram.sv $(ROOT)/rtl/core/conv2d_stage.sv
COCOTB_TOPLEVEL     := conv2d_stage
COCOTB_TEST_MODULES := test_conv2d_stage
COMPILE_ARGS += -Pconv2d_stage.Width=$(WIDTH) -Pconv2d_stage.Height=$(HEIGHT) -Pconv2d_stage.K=$(K)

include $(ROOT)/tests/common/cocotb.mk
