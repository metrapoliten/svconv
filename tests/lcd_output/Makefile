# Тесты кадрового буфера и вывода на RGB-LCD: make test [SCALE=1|2] [BITS=5,6,5|6,6,6]

ROOT := $(abspath ../..)

SCALE ?= 2
BITS  ?= 5,6,5
export SCALE BITS
comma := ,
BITS_LIST := $(subst $(comma), ,$(BITS))

VERILOG_SOURCES := $(addprefix $(ROOT)/rtl/video/, \
                     video_timing.sv frame_buffer.sv lcd_frame_reader.sv lcd_output.sv) \
                   $(abspath lcd_output_tb.sv)
COCOTB_TOPLEVEL     := lcd_output_tb
COCOTB_TEST_MODULES := test_lcd_output
COMPILE_ARGS += -Plcd_output_tb.Scale=$(SCALE) -Plcd_output_tb.RBits=$(word 1,$(BITS_LIST)) \
                -Plcd_output_tb.GBits=$(word 2,$(BITS_LIST)) -Plcd_output_tb.BBits=$(word 3,$(BITS_LIST))

include $(ROOT)/tests/common/cocotb.mk
