ROOT := ../..

.PHONY: test clean

test: button_tb.vvp
	vvp -n $< | tee sim.log
	! grep -q FAIL sim.log

button_tb.vvp: button_tb.sv $(ROOT)/rtl/util/button.sv $(ROOT)/rtl/util/level_sync.sv
	iverilog -g2012 -Wall -o $@ $^

clean:
	rm -f button_tb.vvp sim.log
