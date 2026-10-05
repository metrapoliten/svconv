# Тесты кадрового буфера и вывода на RGB-LCD: make test

ROOT := $(abspath ../..)

VERILOG_SOURCES := $(addprefix $(ROOT)/rtl/video/, \
                     video_timing.sv frame_buffer.sv lcd_frame_reader.sv lcd_output.sv) \
                   $(abspath lcd_output_tb.sv)
COCOTB_TOPLEVEL     := lcd_output_tb
COCOTB_TEST_MODULES := test_lcd_output

include $(ROOT)/tests/common/cocotb.mk
