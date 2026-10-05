ROOT := ../..

.PHONY: test clean

test: button_tb.vvp
	# Код завершения симулятора проверяется отдельно: в конвейере с tee он бы потерялся.
	vvp -n $< > sim.log 2>&1; status=$$?; cat sim.log; test $$status -eq 0
	! grep -q FAIL sim.log

button_tb.vvp: button_tb.sv $(ROOT)/rtl/util/button.sv $(ROOT)/rtl/util/level_sync.sv
	iverilog -g2012 -Wall -o $@ $^

clean:
	rm -f button_tb.vvp sim.log
