# Сборка и загрузка прошивок для Tang Primer 20K.
#
#   make uart_bench        — синтез, размещение и трассировка стенда uart_bench
#                            (результат: build/primer20k/uart_bench/impl/pnr/uart_bench.fs)
#   make load-uart_bench   — загрузить битстрим в SRAM ПЛИС (до выключения питания; flash не трогается)
#   make camera_lcd LCD=43 — камера -> свёртки -> RGB-LCD; LCD=43 — 4,3" 480×272, LCD=50 — 5" 800×480
#   make load-camera_lcd LCD=43
#
# Путь к gw_sh можно переопределить: make GW_SH=/path/to/gw_sh uart_bench

GW_SH       ?= $(HOME)/dev/fpga_tools/bin/gw_sh
LOADER      ?= openFPGALoader
BOARD       := tangprimer20k
PYTHON      ?= python3

BOARD_DIR   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT        := $(abspath $(BOARD_DIR)/../..)
BUILD_DIR   := $(ROOT)/build/primer20k
GEN_HEX     := $(PYTHON) $(ROOT)/model/gen_hex.py

LCD         ?= 43
CAM_TOP     := camera_lcd_$(LCD)_top

.PHONY: uart_bench load-uart_bench camera_lcd load-camera_lcd clean

uart_bench:
	mkdir -p $(BUILD_DIR)/uart_bench
	# Файлы инициализации памяти ($readmemh) кладутся в каталог сборки.
	$(GEN_HEX) kernels --k 5 -o $(BUILD_DIR)/uart_bench/kernels.hex
	$(GEN_HEX) pattern --size 160x120 -o $(BUILD_DIR)/uart_bench/image.hex
	# Без QT_QPA_PLATFORM=minimal gw_sh падает при инициализации Qt.
	cd $(BUILD_DIR)/uart_bench && QT_QPA_PLATFORM=minimal $(GW_SH) $(BOARD_DIR)/uart_bench.tcl

load-uart_bench:
	$(LOADER) -b $(BOARD) $(BUILD_DIR)/uart_bench/impl/pnr/uart_bench.fs

camera_lcd:
	mkdir -p $(BUILD_DIR)/$(CAM_TOP)
	$(GEN_HEX) kernels --k 5 -o $(BUILD_DIR)/$(CAM_TOP)/kernels.hex
	cd $(BUILD_DIR)/$(CAM_TOP) && TOP=$(CAM_TOP) QT_QPA_PLATFORM=minimal $(GW_SH) $(BOARD_DIR)/camera_lcd.tcl

load-camera_lcd:
	$(LOADER) -b $(BOARD) $(BUILD_DIR)/$(CAM_TOP)/impl/pnr/$(CAM_TOP).fs

clean:
	rm -rf $(BUILD_DIR)
