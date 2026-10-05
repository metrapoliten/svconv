# Сквозной тест верхнего модуля стенда камеры для Primer 20K (camera_uart_top): камера 640×480,
# прореживание до 160×120, цепочка по умолчанию, сброс после включения. UART ускорен (4 такта
# на бит), иначе выгрузка двух кадров в симуляции шла бы около часа. make test

ROOT := $(abspath ../..)

CLK_FREQ := 27000000
BAUD     := 6750000
export CLK_FREQ BAUD

VERILOG_SOURCES := $(addprefix $(ROOT)/rtl/, \
                     util/uart_tx.sv util/uart_rx.sv util/level_sync.sv util/pulse_sync.sv \
                     core/sdp_ram.sv core/conv_postprocess.sv core/conv2d_stage.sv core/kernel_rom.sv core/conv_pipeline.sv \
                     core/rgb565_to_gray.sv core/frame_decimator.sv video/frame_buffer.sv \
                     camera/sccb_writer.sv camera/ov7670_init.sv camera/dvp_capture.sv camera/camera_pipeline.sv \
                     bench/camera_uart.sv) \
                   $(ROOT)/boards/primer20k/camera_uart_top.sv
COCOTB_TOPLEVEL     := camera_uart_top
COCOTB_TEST_MODULES := test_camera_uart_top
COMPILE_ARGS += -Pcamera_uart_top.ClkFreq=$(CLK_FREQ) -Pcamera_uart_top.Baud=$(BAUD)
GEN_HEX := python3 $(ROOT)/model/gen_hex.py kernels --k 5 -o kernels.hex

include $(ROOT)/tests/common/cocotb.mk
