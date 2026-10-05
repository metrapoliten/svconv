`timescale 1ns / 1ps

// Генератор видеотаймингов для RGB-LCD в режиме DE: дисплею нужны только признак видимого
// пикселя (DE) и полный период строки и кадра, синхроимпульсы не выводятся.
//
// Строка: HActive видимых пикселей, затем HBlank тактов гашения; кадр устроен так же по строкам
// (VActive видимых строк, VBlank строк гашения).
//
// x_o, y_o — координаты текущего пикселя внутри видимой области (имеют смысл при de_o = 1).
// Все выходы регистровые и относятся к одному и тому же пикселю.
module video_timing #(
    parameter int unsigned HActive = 800,
    parameter int unsigned HBlank = 392,
    parameter int unsigned VActive = 480,
    parameter int unsigned VBlank = 53,
    localparam int unsigned HTotal = HActive + HBlank,
    localparam int unsigned VTotal = VActive + VBlank,
    localparam int unsigned HW = $clog2(HTotal),
    localparam int unsigned VW = $clog2(VTotal)
) (
    input logic clk_i,  // пиксельная частота
    input logic rst_i,  // синхронный сброс, активный уровень 1

    output logic          de_o,
    output logic [HW-1:0] x_o,
    output logic [VW-1:0] y_o
);

  logic [HW-1:0] h_q;
  logic [VW-1:0] v_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      h_q <= '0;
      v_q <= '0;
    end else if (h_q == HW'(HTotal - 1)) begin
      h_q <= '0;
      v_q <= (v_q == VW'(VTotal - 1)) ? '0 : v_q + 1'b1;
    end else begin
      h_q <= h_q + 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) de_o <= 1'b0;
    else de_o <= (h_q < HW'(HActive)) && (v_q < VW'(VActive));
    x_o <= h_q;
    y_o <= v_q;
  end

endmodule
