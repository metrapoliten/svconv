# Проверки всего проекта.
#
#   make test   — тесты эталонной модели (pytest) и все тестбенчи из tests/*/ (iverilog)
#   make lint   — линтер verible
#   make format — проверка форматирования verible (без изменения файлов)

SV_SOURCES := $(shell find rtl boards tests -name '*.sv' 2>/dev/null)
TEST_DIRS  := $(dir $(wildcard tests/*/Makefile))

.PHONY: test lint format clean

test:
	python3 -m pytest -q model
	@set -e; for d in $(TEST_DIRS); do echo "== $$d"; $(MAKE) -s -C $$d test; done

lint:
	verible-verilog-lint $(SV_SOURCES)

# --verify работает только для одного файла за запуск.
format:
	@set -e; for f in $(SV_SOURCES); do verible-verilog-format --verify $$f; done

clean:
	@for d in $(TEST_DIRS); do $(MAKE) -s -C $$d clean; done
