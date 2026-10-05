# Сквозной тест camera_display: модель камеры -> обработка -> снимок экрана LCD. make test

ROOT := $(abspath ../..)

K := 5
export K

VERILOG_SOURCES := $(addprefix $(ROOT)/rtl/, \
                     core/sdp_ram.sv core/kernel_rom.sv core/conv_postprocess.sv core/conv2d_stage.sv core/conv_pipeline.sv \
                     core/rgb565_to_gray.sv \
                     video/video_timing.sv video/frame_buffer.sv video/lcd_frame_reader.sv \
                     video/lcd_output.sv camera/dvp_capture.sv camera/camera_pipeline.sv \
                     camera/camera_display.sv)
COCOTB_TOPLEVEL     := camera_display
COCOTB_TEST_MODULES := test_camera_display
# Конфигурация как на Mega 138K Pro, но в маленьком масштабе: кадр камеры 16×12, экран 40×30,
# без увеличения (картинка по центру), цвет RGB666.
COMPILE_ARGS += -Pcamera_display.Width=16 -Pcamera_display.Height=12 \
                -Pcamera_display.HActive=40 -Pcamera_display.HFront=3 -Pcamera_display.HSync=4 \
                -Pcamera_display.HBack=5 -Pcamera_display.VActive=30 -Pcamera_display.VFront=2 \
                -Pcamera_display.VSync=3 -Pcamera_display.VBack=4 -Pcamera_display.Scale=1 \
                -Pcamera_display.RBits=6 -Pcamera_display.GBits=6 -Pcamera_display.BBits=6
GEN_HEX := python3 $(ROOT)/model/gen_hex.py kernels --k $(K) -o kernels.hex

include $(ROOT)/tests/common/cocotb.mk
