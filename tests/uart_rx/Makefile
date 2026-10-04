ROOT := ../..

.PHONY: test clean

test: uart_rx_tb.vvp
	vvp -n $< | tee sim.log
	! grep -q FAIL sim.log

uart_rx_tb.vvp: uart_rx_tb.sv $(ROOT)/rtl/util/uart_rx.sv $(ROOT)/rtl/util/uart_tx.sv \
                $(ROOT)/rtl/util/level_sync.sv
	iverilog -g2012 -Wall -o $@ $^

clean:
	rm -f uart_rx_tb.vvp uart_rx_tb.vcd sim.log
