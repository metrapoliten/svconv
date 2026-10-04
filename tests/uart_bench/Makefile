# Тесты uart_bench (стенд целиком): make test

ROOT := $(abspath ../..)

WIDTH    ?= 16
HEIGHT   ?= 12
K        := 5
CLK_FREQ := 800
BAUD     := 100
export WIDTH HEIGHT K CLK_FREQ BAUD

VERILOG_SOURCES := $(addprefix $(ROOT)/rtl/, \
                     util/uart_tx.sv util/uart_rx.sv util/level_sync.sv \
                     core/sdp_ram.sv core/conv_postprocess.sv core/conv2d_stage.sv core/kernel_rom.sv core/conv_pipeline.sv \
                     bench/frame_rom_source.sv bench/uart_bench.sv)
COCOTB_TOPLEVEL     := uart_bench
COCOTB_TEST_MODULES := test_uart_bench
COMPILE_ARGS += -Puart_bench.Width=$(WIDTH) -Puart_bench.Height=$(HEIGHT) -Puart_bench.K=$(K) \
                -Puart_bench.ClkFreq=$(CLK_FREQ) -Puart_bench.Baud=$(BAUD)
GEN_HEX := python3 $(ROOT)/model/gen_hex.py kernels --k $(K) -o kernels.hex && \
           python3 $(ROOT)/model/gen_hex.py pattern --size $(WIDTH)x$(HEIGHT) -o image.hex

include $(ROOT)/tests/common/cocotb.mk
