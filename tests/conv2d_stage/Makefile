# Тесты conv2d_stage на cocotb + iverilog.
#
#   make test                          — кадр 16×12, ядро 5×5 (быстро)
#   make test WIDTH=160 HEIGHT=120     — рабочий размер кадра
#   make test WAVES=1                  — с записью временных диаграмм (sim_build/*.fst)

ROOT := $(abspath ../..)

WIDTH  ?= 16
HEIGHT ?= 12
K      ?= 5
export WIDTH HEIGHT K

SIM            ?= icarus
TOPLEVEL_LANG  := verilog
VERILOG_SOURCES := $(ROOT)/rtl/core/sdp_ram.sv $(ROOT)/rtl/core/conv2d_stage.sv
COCOTB_TOPLEVEL := conv2d_stage
COCOTB_TEST_MODULES := test_conv2d_stage
COMPILE_ARGS += -Pconv2d_stage.Width=$(WIDTH) -Pconv2d_stage.Height=$(HEIGHT) -Pconv2d_stage.K=$(K)

export PYTHONPATH := $(ROOT)/model:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: test
# Пересобираем каждый раз: параметры кадра передаются при компиляции.
test:
	rm -rf sim_build results.xml
	$(MAKE) sim
	! grep -q '<failure' results.xml
