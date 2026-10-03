`timescale 1ns / 1ps

// Формальная проверка uart_tx (SymbiYosys): свойства доказываются для всех входных
// последовательностей. Битовый интервал уменьшен до ClksPerBit тактов, чтобы доказательство
// было быстрым; логика модуля от него не зависит.
module uart_tx_fv (
    input logic       clk_i,
    input logic       rst_i,
    input logic [7:0] data_i,
    input logic       valid_i
);

  localparam int unsigned ClksPerBit = 4;
  localparam int unsigned FrameClks  = 10 * ClksPerBit;

  logic ready, tx;

  uart_tx #(
      .ClkFreq(ClksPerBit),
      .Baud   (1)
  ) dut (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .data_i (data_i),
      .valid_i(valid_i),
      .ready_o(ready),
      .tx_o   (tx)
  );

  // Первый такт — сброс.
  logic init_q = 1'b1;
  always_ff @(posedge clk_i) init_q <= 1'b0;
  always_comb if (init_q) assume (rst_i);

  // Наблюдатель: такты с момента приёма байта и сам байт (кадр — {стоп, данные, старт}).
  logic [7:0] busy_q;
  logic [9:0] frame_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      busy_q <= '0;
    end else if (valid_i && ready) begin
      busy_q  <= 8'd1;
      frame_q <= {1'b1, data_i, 1'b0};
    end else if (busy_q != 0) begin
      busy_q <= (busy_q == 8'(FrameClks)) ? '0 : busy_q + 1'b1;
    end
  end

  always_comb begin
    if (!init_q && !rst_i) begin
      // Передача длится ровно FrameClks тактов: всё это время передатчик занят.
      assert (ready == (busy_q == 0));
      // В покое линия в 1.
      if (ready) assert (tx == 1'b1);
      // Бит i кадра держится на линии ClksPerBit тактов; выход регистровый, поэтому
      // кадр сдвинут на такт относительно busy_q.
      if (busy_q >= 2) assert (tx == frame_q[(busy_q-2)/ClksPerBit]);
    end
  end

endmodule
