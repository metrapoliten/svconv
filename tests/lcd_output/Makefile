# Тесты кадрового буфера и вывода на RGB-LCD: make test [BITS=6,6,6|5,6,5]

ROOT := $(abspath ../..)

BITS ?= 6,6,6
export BITS
comma := ,
BITS_LIST := $(subst $(comma), ,$(BITS))

VERILOG_SOURCES := $(addprefix $(ROOT)/rtl/video/, \
                     video_timing.sv frame_buffer.sv lcd_frame_reader.sv lcd_output.sv) \
                   $(abspath lcd_output_tb.sv)
COCOTB_TOPLEVEL     := lcd_output_tb
COCOTB_TEST_MODULES := test_lcd_output
COMPILE_ARGS += -Plcd_output_tb.RBits=$(word 1,$(BITS_LIST)) \
                -Plcd_output_tb.GBits=$(word 2,$(BITS_LIST)) -Plcd_output_tb.BBits=$(word 3,$(BITS_LIST))

include $(ROOT)/tests/common/cocotb.mk
