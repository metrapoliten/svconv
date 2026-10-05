# Проверки всего проекта.
#
#   make test     — тесты модели и клиентов (pytest: model/, tools/) и тесты модулей из tests/*/
#                   (iverilog, cocotb)
#   make test-top — сквозные тесты верхних модулей плат (tests/*_top/): рабочие размеры кадра,
#                   поэтому идут долго (от нескольких минут до получаса каждый); перед загрузкой
#                   прошивки в плату
#   make lint   — линтер verible
#   make format — проверка форматирования verible (без изменения файлов)
#   make formal — формальная проверка (SymbiYosys, решатель z3): нативный из OSS CAD Suite, если
#                 задана переменная окружения OSS_CAD_SUITE (каталог распаковки, примерно вдвое
#                 быстрее), иначе — из пакета yowasp-yosys (requirements.txt)

# Тесты на cocotb и модель используют окружение .venv (см. requirements.txt).
export PATH := $(CURDIR)/.venv/bin:$(PATH)

# В formal/ — только исходники первого уровня (во вложенных каталогах — копии SymbiYosys).
SV_SOURCES := $(shell find rtl boards tests -name '*.sv' 2>/dev/null) $(wildcard formal/*/*.sv)
TOP_TEST_DIRS := $(dir $(wildcard tests/*_top/Makefile tests/*_top_*/Makefile))
TEST_DIRS  := $(filter-out $(TOP_TEST_DIRS),$(dir $(wildcard tests/*/Makefile)))
SBY_FILES  ?= $(wildcard formal/*/*.sby)
# Обёртки в $(OSS_CAD_SUITE)/bin сами находят остальные программы набора (yosys, z3); в PATH
# набор не добавляется, чтобы не подменять системные iverilog и другие.
ifneq ($(OSS_CAD_SUITE),)
SBY        ?= $(OSS_CAD_SUITE)/bin/sby
else
# Инструменты YoWASP называются иначе, чем обычные yosys/yosys-smtbmc.
SBY        ?= yowasp-sby --yosys yowasp-yosys --smtbmc yowasp-yosys-smtbmc \
              --witness yowasp-yosys-witness
endif

.PHONY: test test-top lint format formal clean

test:
	python3 -m pytest -q model tools
	@set -e; for d in $(TEST_DIRS); do echo "== $$d"; $(MAKE) -s -C $$d test; done

test-top:
	@set -e; for d in $(TOP_TEST_DIRS); do echo "== $$d"; $(MAKE) -s -C $$d test; done

lint:
	verible-verilog-lint $(SV_SOURCES)

# --verify работает только для одного файла за запуск.
format:
	@set -e; for f in $(SV_SOURCES); do verible-verilog-format --verify $$f; done

# Доказательства идут от секунд до десятков минут (дольше всех — uart_rx); одно можно запустить
# так: make formal SBY_FILES=formal/uart_tx/uart_tx.sby
formal:
	python3 model/gen_hex.py random --count 78 --seed 1 -o formal/kernel_rom/rom.hex
	@set -e; for f in $(SBY_FILES); do echo "== $$f"; (cd $$(dirname $$f) && $(SBY) -f $$(basename $$f)); done

clean:
	@for d in $(TEST_DIRS) $(TOP_TEST_DIRS); do $(MAKE) -s -C $$d clean; done
