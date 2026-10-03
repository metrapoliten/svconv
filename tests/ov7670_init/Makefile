# Тест ov7670_init (вместе с sccb_writer): make test
# Частота clk_i уменьшена до 400 кГц: четверть периода SCCB — 1 такт, 1 мс — 400 тактов.

ROOT := $(abspath ../..)

CLK_FREQ := 400000
export CLK_FREQ

VERILOG_SOURCES     := $(ROOT)/rtl/camera/sccb_writer.sv $(ROOT)/rtl/camera/ov7670_init.sv
COCOTB_TOPLEVEL     := ov7670_init
COCOTB_TEST_MODULES := test_ov7670_init
COMPILE_ARGS += -Pov7670_init.ClkFreq=$(CLK_FREQ) -Pov7670_init.SccbFreq=100000

include $(ROOT)/tests/common/cocotb.mk
