# Проверки всего проекта.
#
#   make test   — тесты эталонной модели (pytest) и все тесты из tests/*/ (iverilog, cocotb)
#   make lint   — линтер verible
#   make format — проверка форматирования verible (без изменения файлов)
#   make formal — формальная проверка (SymbiYosys из пакета yowasp-yosys, решатель z3)

# Тесты на cocotb и модель используют окружение .venv (см. requirements.txt).
export PATH := $(CURDIR)/.venv/bin:$(PATH)

# В formal/ — только исходники первого уровня (во вложенных каталогах — копии SymbiYosys).
SV_SOURCES := $(shell find rtl boards tests -name '*.sv' 2>/dev/null) $(wildcard formal/*/*.sv)
TEST_DIRS  := $(dir $(wildcard tests/*/Makefile))
SBY_FILES  := $(wildcard formal/*/*.sby)
# Инструменты YoWASP называются иначе, чем обычные yosys/yosys-smtbmc.
SBY        := yowasp-sby --yosys yowasp-yosys --smtbmc yowasp-yosys-smtbmc \
              --witness yowasp-yosys-witness

.PHONY: test lint format formal clean

test:
	python3 -m pytest -q model
	@set -e; for d in $(TEST_DIRS); do echo "== $$d"; $(MAKE) -s -C $$d test; done

lint:
	verible-verilog-lint $(SV_SOURCES)

# --verify работает только для одного файла за запуск.
format:
	@set -e; for f in $(SV_SOURCES); do verible-verilog-format --verify $$f; done

formal:
	@set -e; for f in $(SBY_FILES); do echo "== $$f"; (cd $$(dirname $$f) && $(SBY) -f $$(basename $$f)); done

clean:
	@for d in $(TEST_DIRS); do $(MAKE) -s -C $$d clean; done
