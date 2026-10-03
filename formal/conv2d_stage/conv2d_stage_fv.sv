`timescale 1ns / 1ps

// Формальная проверка управления conv2d_stage (кадр 4×4, окно 3×3). Вычисления (свёртка,
// постобработка) проверяются отдельно: тестами cocotb против модели и formal/conv_postprocess;
// здесь веса и пиксели нулевые: от их значений управление не зависит, а решателю не приходится
// перебирать данные в строчных буферах и умножителях.
//
//   - каждый входной пиксель порождает ровно один выходной: valid_o — это valid_i, задержанный
//     ровно на Latency тактов (при любых паузах);
//   - sof_o бывает только вместе с valid_o;
//   - (задача continuous) sof_o не появляется раньше первого sof_i. Здесь пиксели подаются
//     каждый такт: состояние каскада меняется только по valid_i, так что паузы на это не влияют.
module conv2d_stage_fv (
    input logic clk_i,
    input logic rst_i,
    input logic valid_i,
    input logic sof_i
);

  localparam int unsigned Width   = 4, Height = 4, K = 3;
  localparam int unsigned Latency = 6;

  logic valid_o, sof_o;
  logic [7:0] data_o;

  conv2d_stage #(
      .Width (Width),
      .Height(Height),
      .K     (K)
  ) dut (
      .clk_i    (clk_i),
      .rst_i    (rst_i),
      .weights_i('0),
      .shift_i  ('0),
      .abs_i    (1'b0),
      .valid_i  (valid_i),
      .sof_i    (sof_i),
      .data_i   (8'd0),
      .valid_o  (valid_o),
      .sof_o    (sof_o),
      .data_o   (data_o)
  );

  logic init_q = 1'b1;
  always_ff @(posedge clk_i) init_q <= 1'b0;
  always_comb assume (rst_i == init_q);
`ifdef CONTINUOUS
  always_comb if (!init_q) assume (valid_i);
`endif

  // Наблюдатель: входные valid, задержанные на Latency тактов, и был ли sof на входе.
  logic [Latency-1:0] valid_sr_q = '0;
  logic seen_sof_q = 1'b0;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      valid_sr_q <= '0;
      seen_sof_q <= 1'b0;
    end else begin
      valid_sr_q <= {valid_sr_q[Latency-2:0], valid_i};
      if (valid_i && sof_i) seen_sof_q <= 1'b1;
    end
  end

  always_comb begin
    if (!init_q) begin
      assert (valid_o == valid_sr_q[Latency-1]);
      if (sof_o) assert (valid_o);
`ifdef CONTINUOUS
      if (sof_o) assert (seen_sof_q);
`endif
    end
  end

endmodule
