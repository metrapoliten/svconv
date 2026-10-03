`timescale 1ns / 1ps

// Тест uart_tx: передаём набор байт подряд (без пауз между ними) и
// декодируем линию TX как приёмник 8N1, выбирая значение в середине каждого бита.
module uart_tx_tb;

  localparam int unsigned ClksPerBit = 8;
  localparam int unsigned NumBytes = 6;
  // Байт i — Bytes[8*i+:8], т.е. передаются 00, FF, A5, 5A, 01, 80
  // (плоский вектор: iverilog не поддерживает параметры-массивы).
  localparam logic [8*NumBytes-1:0] Bytes = 48'h80_01_5A_A5_FF_00;

  logic       clk = 1'b0;
  logic       rst = 1'b1;
  logic [7:0] data;
  logic       valid = 1'b0;
  logic       ready;
  logic       tx;

  always #5 clk = ~clk;

  uart_tx #(
      .ClkFreq(ClksPerBit * 100),
      .Baud   (100)
  ) dut (
      .clk_i  (clk),
      .rst_i  (rst),
      .data_i (data),
      .valid_i(valid),
      .ready_o(ready),
      .tx_o   (tx)
  );

  // Временные диаграммы для GTKWave: uart_tx_tb.vcd.
  initial begin
    $dumpfile("uart_tx_tb.vcd");
    $dumpvars(0, uart_tx_tb);
  end

  // Источник: выставляет следующий байт сразу, как только передатчик готов.
  initial begin
    repeat (3) @(posedge clk);
    rst <= 1'b0;
    for (int i = 0; i < NumBytes; i++) begin
      data  <= Bytes[8*i+:8];
      valid <= 1'b1;
      do @(posedge clk); while (!ready);
    end
    valid <= 1'b0;
  end

  // Приёмник: ждёт старт-бит, затем выбирает биты в их середине.
  int errors = 0;

  initial begin
    logic [7:0] rx_byte;
    @(negedge rst);
    for (int i = 0; i < NumBytes; i++) begin
      @(negedge tx);
      repeat (ClksPerBit / 2) @(posedge clk);
      if (tx !== 1'b0) begin
        $display("FAIL: byte %0d: no start bit", i);
        errors++;
      end
      for (int b = 0; b < 8; b++) begin
        repeat (ClksPerBit) @(posedge clk);
        rx_byte[b] = tx;
      end
      repeat (ClksPerBit) @(posedge clk);
      if (tx !== 1'b1) begin
        $display("FAIL: byte %0d: no stop bit", i);
        errors++;
      end
      if (rx_byte !== Bytes[8*i+:8]) begin
        $display("FAIL: byte %0d: received %h, expected %h", i, rx_byte, Bytes[8*i+:8]);
        errors++;
      end
    end
    if (errors == 0) $display("PASS: all %0d bytes received correctly", NumBytes);
    $finish;
  end

  // Защита от зависания.
  initial begin
    #(10 * ClksPerBit * 12 * (NumBytes + 2) * 2);
    $display("FAIL: timeout");
    $finish;
  end

endmodule
