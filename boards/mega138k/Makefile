# Сборка и загрузка прошивок для Tang Mega 138K Pro.
#
#   make camera_lcd        — камера -> свёртки (640×480) -> дисплей 5" 800×480 SH500Q01Z
#   make load-camera_lcd   — загрузить битстрим в SRAM ПЛИС (до выключения питания; flash не трогается)
#
# Чип по умолчанию — серийный GW5AST-LV138FPG676AC1/I0, версия кристалла B, как в проектах Sipeed для
# этой платы. Другой: make DEVICE=GW5AST-LV138FPG676AES camera_lcd (инженерная версия) или
# make DEVICE_VERSION=C camera_lcd.
# Gowin EDA: каталог установки — переменная окружения GOWIN_HOME (в нём bin/gw_sh); без неё
# gw_sh ищется в PATH. Можно указать и сам gw_sh: make GW_SH=/path/to/gw_sh ...
# Пути к программам могут содержать пробелы; путь к самому репозиторию — нет (make не умеет).

GW_SH       ?= $(if $(GOWIN_HOME),$(GOWIN_HOME)/bin/gw_sh,gw_sh)
LOADER      ?= openFPGALoader
BOARD       := tangmega138k
PYTHON      ?= python3
DEVICE      ?= GW5AST-LV138FPG676AC1/I0
DEVICE_VERSION ?= B

BOARD_DIR   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT        := $(abspath $(BOARD_DIR)/../..)

# Окружение Python проекта (.venv), если оно есть, — первым в PATH, как в корневом Makefile:
# так находятся cocotb, NumPy и Pillow без ручной активации.
ifneq ($(wildcard $(ROOT)/.venv/bin),)
export PATH := $(ROOT)/.venv/bin:$(PATH)
endif

BUILD_DIR   := $(ROOT)/build/mega138k
GEN_HEX     := $(PYTHON) $(ROOT)/model/gen_hex.py

.PHONY: camera_lcd load-camera_lcd clean

camera_lcd:
	mkdir -p $(BUILD_DIR)/camera_lcd
	$(GEN_HEX) kernels --k 5 -o $(BUILD_DIR)/camera_lcd/kernels.hex
	# Без QT_QPA_PLATFORM=minimal gw_sh падает при инициализации Qt.
	cd $(BUILD_DIR)/camera_lcd && DEVICE=$(DEVICE) DEVICE_VERSION=$(DEVICE_VERSION) QT_QPA_PLATFORM=minimal "$(GW_SH)" $(BOARD_DIR)/camera_lcd.tcl
	# Запас на входе панели: Gowin сам выходы с DCLK не сравнивает (см. camera_lcd.sdc).
	$(PYTHON) $(ROOT)/tools/check_lcd_timing.py $(BUILD_DIR)/camera_lcd/impl/pnr/camera_lcd.tr

load-camera_lcd:
	"$(LOADER)" -b $(BOARD) $(BUILD_DIR)/camera_lcd/impl/pnr/camera_lcd.fs

clean:
	rm -rf $(BUILD_DIR)
