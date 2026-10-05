# Общая часть Makefile тестов верхнего модуля для Mega 138K Pro (camera_lcd_top). Подключается в
# конце Makefile теста, где заданы ROOT, COCOTB_TEST_MODULES и, если нужно, COMPILE_ARGS.
#
# PLL и ODDR моделируются библиотекой Gowin: $GOWIN_HOME/simlib/gw5a/prim_sim.v из установленного
# Gowin EDA (переменная окружения GOWIN_HOME) или файл, заданный в GOWIN_SIM; в репозиторий она
# не входит. Если библиотеки нет, тест пропускается. Путь к библиотеке не должен содержать
# пробелов: он входит в список исходников, а make делит списки по пробелам.

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
COCOTB_TOPLEVEL := camera_lcd_top
# Модель ODDR обращается к глобальному сбросу GSR.GSRO: модуль GSR — второй корень иерархии
# (вход не подключён, глобальный сброс не срабатывает).
COMPILE_ARGS += -s GSR
GEN_HEX := python3 $(ROOT)/model/gen_hex.py kernels --k 5 -o kernels.hex

include $(ROOT)/tests/common/cocotb.mk
endif
