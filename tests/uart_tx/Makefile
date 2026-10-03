ROOT := ../..

.PHONY: test clean

test: uart_tx_tb.vvp
	vvp -n $< | tee sim.log
	! grep -q FAIL sim.log

uart_tx_tb.vvp: uart_tx_tb.sv $(ROOT)/rtl/util/uart_tx.sv
	iverilog -g2012 -Wall -o $@ $^

clean:
	rm -f uart_tx_tb.vvp uart_tx_tb.vcd sim.log
