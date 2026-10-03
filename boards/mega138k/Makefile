# Сборка и загрузка прошивок для Tang Mega 138K Pro.
#
#   make camera_lcd        — камера -> свёртки (640×480) -> дисплей 5" 800×480 SH500Q01Z
#   make load-camera_lcd   — загрузить битстрим в SRAM ПЛИС (до выключения питания; flash не трогается)
#
# Чип: make DEVICE=GW5AST-LV138FPG676AC1/I0 camera_lcd (по умолчанию — инженерная версия AES).
# Путь к gw_sh можно переопределить: make GW_SH=/path/to/gw_sh camera_lcd

GW_SH       ?= $(HOME)/dev/fpga_tools/bin/gw_sh
LOADER      ?= openFPGALoader
BOARD       := tangmega138k
PYTHON      ?= python3
DEVICE      ?= GW5AST-LV138FPG676AES

BOARD_DIR   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT        := $(abspath $(BOARD_DIR)/../..)
BUILD_DIR   := $(ROOT)/build/mega138k
GEN_HEX     := $(PYTHON) $(ROOT)/model/gen_hex.py

.PHONY: camera_lcd load-camera_lcd clean

camera_lcd:
	mkdir -p $(BUILD_DIR)/camera_lcd
	$(GEN_HEX) kernels --k 5 -o $(BUILD_DIR)/camera_lcd/kernels.hex
	# Без QT_QPA_PLATFORM=minimal gw_sh падает при инициализации Qt.
	cd $(BUILD_DIR)/camera_lcd && DEVICE=$(DEVICE) QT_QPA_PLATFORM=minimal $(GW_SH) $(BOARD_DIR)/camera_lcd.tcl

load-camera_lcd:
	$(LOADER) -b $(BOARD) $(BUILD_DIR)/camera_lcd/impl/pnr/camera_lcd.fs

clean:
	rm -rf $(BUILD_DIR)
