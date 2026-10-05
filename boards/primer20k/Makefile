# Сборка и загрузка прошивок для Tang Primer 20K.
#
#   make uart_bench        — синтез, размещение и трассировка стенда uart_bench
#                            (результат: build/primer20k/uart_bench/impl/pnr/uart_bench.fs)
#   make load-uart_bench   — загрузить битстрим в SRAM ПЛИС (до выключения питания; flash не трогается)
#   make camera_uart       — камера на проводах -> свёртки -> кадры по UART (без дисплея)
#   make load-camera_uart
#
# Gowin EDA: каталог установки — переменная окружения GOWIN_HOME (в нём bin/gw_sh); без неё
# gw_sh ищется в PATH. Можно указать и сам gw_sh: make GW_SH=/path/to/gw_sh ...
# Пути к программам могут содержать пробелы; путь к самому репозиторию — нет (make не умеет).

GW_SH       ?= $(if $(GOWIN_HOME),$(GOWIN_HOME)/bin/gw_sh,gw_sh)
LOADER      ?= openFPGALoader
BOARD       := tangprimer20k
PYTHON      ?= python3

BOARD_DIR   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT        := $(abspath $(BOARD_DIR)/../..)

# Окружение Python проекта (.venv), если оно есть, — первым в PATH, как в корневом Makefile:
# так находятся cocotb, NumPy и Pillow без ручной активации.
ifneq ($(wildcard $(ROOT)/.venv/bin),)
export PATH := $(ROOT)/.venv/bin:$(PATH)
endif

BUILD_DIR   := $(ROOT)/build/primer20k
GEN_HEX     := $(PYTHON) $(ROOT)/model/gen_hex.py

.PHONY: uart_bench load-uart_bench camera_uart load-camera_uart clean

uart_bench:
	mkdir -p $(BUILD_DIR)/uart_bench
	# Файлы инициализации памяти ($readmemh) кладутся в каталог сборки.
	$(GEN_HEX) kernels --k 5 -o $(BUILD_DIR)/uart_bench/kernels.hex
	$(GEN_HEX) pattern --size 160x120 -o $(BUILD_DIR)/uart_bench/image.hex
	# Без QT_QPA_PLATFORM=minimal gw_sh падает при инициализации Qt.
	cd $(BUILD_DIR)/uart_bench && QT_QPA_PLATFORM=minimal "$(GW_SH)" $(BOARD_DIR)/uart_bench.tcl

load-uart_bench:
	"$(LOADER)" -b $(BOARD) $(BUILD_DIR)/uart_bench/impl/pnr/uart_bench.fs

camera_uart:
	mkdir -p $(BUILD_DIR)/camera_uart
	$(GEN_HEX) kernels --k 5 -o $(BUILD_DIR)/camera_uart/kernels.hex
	cd $(BUILD_DIR)/camera_uart && QT_QPA_PLATFORM=minimal "$(GW_SH)" $(BOARD_DIR)/camera_uart.tcl

load-camera_uart:
	"$(LOADER)" -b $(BOARD) $(BUILD_DIR)/camera_uart/impl/pnr/camera_uart.fs

clean:
	rm -rf $(BUILD_DIR)
