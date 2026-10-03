# Тесты camera_uart (стенд «камера -> UART»): make test
# Кадр камеры 64×48 -> 16×12, UART — 8 тактов clk_i на бит.

ROOT := $(abspath ../..)

K := 5
CLK_FREQ := 800
BAUD := 100
export K CLK_FREQ BAUD

VERILOG_SOURCES := $(addprefix $(ROOT)/rtl/, \
                     util/uart_tx.sv util/uart_rx.sv \
                     core/sdp_ram.sv core/kernel_rom.sv core/conv_postprocess.sv core/conv2d_stage.sv \
                     core/conv_pipeline.sv core/rgb565_to_gray.sv core/frame_decimator.sv \
                     video/frame_buffer.sv camera/dvp_capture.sv camera/camera_pipeline.sv \
                     bench/camera_uart.sv)
COCOTB_TOPLEVEL     := camera_uart
COCOTB_TEST_MODULES := test_camera_uart
COMPILE_ARGS += -Pcamera_uart.Width=16 -Pcamera_uart.Height=12 -Pcamera_uart.Factor=4 \
                -Pcamera_uart.ClkFreq=$(CLK_FREQ) -Pcamera_uart.Baud=$(BAUD)
GEN_HEX := python3 $(ROOT)/model/gen_hex.py kernels --k $(K) -o kernels.hex

include $(ROOT)/tests/common/cocotb.mk
