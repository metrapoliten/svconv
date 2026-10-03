`timescale 1ns / 1ps

// Перевод потока RGB565 в оттенки серого (8 бит), как rgb565_to_rgb888() + rgb888_to_gray()
// в модели: компоненты расширяются до 8 бит повторением старших битов, затем
// серый = (77*R + 150*G + 29*B) >> 8 (формула из курса). Задержка — 1 такт.
module rgb565_to_gray (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1

    input logic        valid_i,
    input logic        sof_i,
    input logic [15:0] data_i,   // {R[4:0], G[5:0], B[4:0]}

    output logic       valid_o,
    output logic       sof_o,
    output logic [7:0] data_o
);

  logic [7:0] r8, g8, b8;
  // Максимум суммы: 256 * 255 < 2^16.
  logic [15:0] luma;

  always_comb begin
    r8   = {data_i[15:11], data_i[15:13]};
    g8   = {data_i[10:5], data_i[10:9]};
    b8   = {data_i[4:0], data_i[4:2]};
    // Операнды явно расширены до 16 бит, чтобы произведения не обрезались до 8 бит.
    luma = {8'd0, r8} * 16'd77 + {8'd0, g8} * 16'd150 + {8'd0, b8} * 16'd29;
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      valid_o <= 1'b0;
      sof_o   <= 1'b0;
    end else begin
      valid_o <= valid_i;
      sof_o   <= valid_i && sof_i;
    end
    data_o <= luma[15:8];
  end

endmodule
