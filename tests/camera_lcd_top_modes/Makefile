# Переключение режимов кнопкой в camera_lcd_top (Mega 138K Pro) на работающей камере: после каждого
# нажатия цепочка перезагружает ядра, и в кадровом буфере устанавливается кадр нового режима.
# Тот же верхний модуль, но кадр камеры 64×48 вместо 640×480 (обработка, переходы между доменами и
# управление те же; высота больше задержки цепочки — 9 строк), SCCB 400 кГц вместо 25 кГц и
# подавление дребезга кнопки 100 тактов (2 мкс) вместо 10 мс — иначе тест шёл бы часами. Полный
# кадр и экран проверяет tests/camera_lcd_top. make test
#
# PLL и ODDR моделируются библиотекой Gowin — см. tests/camera_lcd_top/Makefile.

ROOT := $(abspath ../..)

CAM_WIDTH       := 64
CAM_HEIGHT      := 48
BTN_STABLE_CLKS := 100
export CAM_WIDTH CAM_HEIGHT BTN_STABLE_CLKS

GOWIN_SIM ?= $(if $(GOWIN_HOME),$(GOWIN_HOME)/simlib/gw5a/prim_sim.v)

ifeq ($(wildcard $(GOWIN_SIM)),)
.PHONY: test clean
test:
	@echo "SKIP: Gowin simulation library not found ($(GOWIN_SIM)); set GOWIN_HOME or GOWIN_SIM"
clean:
else
VERILOG_SOURCES := $(addprefix $(ROOT)/rtl/, \
                     util/level_sync.sv util/button.sv \
                     core/sdp_ram.sv core/conv_postprocess.sv core/conv2d_stage.sv core/kernel_rom.sv core/conv_pipeline.sv \
                     core/rgb565_to_gray.sv \
                     video/video_timing.sv video/frame_buffer.sv video/lcd_frame_reader.sv video/lcd_output.sv \
                     camera/sccb_writer.sv camera/ov7670_init.sv camera/dvp_capture.sv camera/camera_pipeline.sv \
                     camera/camera_display.sv) \
                   $(ROOT)/boards/mega138k/camera_lcd_top.sv $(GOWIN_SIM)
COCOTB_TOPLEVEL     := camera_lcd_top
COMPILE_ARGS += -Pcamera_lcd_top.CamWidth=$(CAM_WIDTH) -Pcamera_lcd_top.CamHeight=$(CAM_HEIGHT) \
                -Pcamera_lcd_top.SccbFreq=400000 -Pcamera_lcd_top.BtnStableClks=$(BTN_STABLE_CLKS)
COMPILE_ARGS += -s GSR
COCOTB_TEST_MODULES := test_camera_lcd_top_modes
GEN_HEX := python3 $(ROOT)/model/gen_hex.py kernels --k 5 -o kernels.hex

include $(ROOT)/tests/common/cocotb.mk
endif
