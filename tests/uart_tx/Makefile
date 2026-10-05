ROOT := ../..

.PHONY: test clean

test: uart_tx_tb.vvp
	# Код завершения симулятора проверяется отдельно: в конвейере с tee он бы потерялся.
	vvp -n $< > sim.log 2>&1; status=$$?; cat sim.log; test $$status -eq 0
	! grep -q FAIL sim.log

uart_tx_tb.vvp: uart_tx_tb.sv $(ROOT)/rtl/util/uart_tx.sv
	iverilog -g2012 -Wall -o $@ $^

clean:
	rm -f uart_tx_tb.vvp uart_tx_tb.vcd sim.log
