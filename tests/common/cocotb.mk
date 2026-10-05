# Общая часть Makefile cocotb-тестов. Подключается в конце Makefile теста, где заданы ROOT,
# VERILOG_SOURCES, COCOTB_TOPLEVEL, COCOTB_TEST_MODULES и, если нужно, GEN_HEX — команды
# генерации .hex-файлов в каталог теста (симуляция запускается из него).
#
#   make test           — пересобрать и прогнать тесты
#   make test WAVES=1   — с записью временных диаграмм (sim_build/*.fst)

# Окружение Python проекта (.venv), если оно есть, — первым в PATH, как в корневом Makefile:
# так находятся cocotb, NumPy и Pillow без ручной активации.
ifneq ($(wildcard $(ROOT)/.venv/bin),)
export PATH := $(ROOT)/.venv/bin:$(PATH)
endif

SIM           ?= icarus
TOPLEVEL_LANG := verilog

export PYTHONPATH := $(ROOT)/model:$(ROOT)/tests/common:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: test
# Пересобираем каждый раз: параметры (размер кадра, K) передаются при компиляции.
test:
	rm -rf sim_build results.xml
	$(GEN_HEX)
	$(MAKE) sim
	! grep -q '<failure' results.xml
