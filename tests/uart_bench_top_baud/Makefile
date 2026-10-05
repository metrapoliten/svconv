# Тест uart_bench_top на рабочей скорости UART (115200 бод при 27 МГц — 234 такта на бит):
# команда p и разбор команд c; кадр не выгружается (его проверяет tests/uart_bench_top с
# ускоренным UART). make test

ROOT := $(abspath ../..)

CLK_FREQ := 27000000
BAUD     := 115200
export CLK_FREQ BAUD

VERILOG_SOURCES := $(addprefix $(ROOT)/rtl/, \
                     util/uart_tx.sv util/uart_rx.sv util/level_sync.sv \
                     core/sdp_ram.sv core/conv_postprocess.sv core/conv2d_stage.sv core/kernel_rom.sv core/conv_pipeline.sv \
                     bench/frame_rom_source.sv bench/uart_bench.sv) \
                   $(ROOT)/boards/primer20k/uart_bench_top.sv
COCOTB_TOPLEVEL     := uart_bench_top
COCOTB_TEST_MODULES := test_uart_bench_top_baud
COMPILE_ARGS += -Puart_bench_top.ClkFreq=$(CLK_FREQ) -Puart_bench_top.Baud=$(BAUD)
# Файлы инициализации — как в boards/primer20k/Makefile.
GEN_HEX := python3 $(ROOT)/model/gen_hex.py kernels --k 5 -o kernels.hex && \
           python3 $(ROOT)/model/gen_hex.py pattern --size 160x120 -o image.hex

include $(ROOT)/tests/common/cocotb.mk
