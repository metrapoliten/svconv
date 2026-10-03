`timescale 1ns / 1ps

// Уменьшение кадра прореживанием: из каждого квадрата Factor×Factor остаётся левый верхний
// пиксель, берётся область OutWidth×OutHeight от левого верхнего угла (остальное отбрасывается).
// Совпадает с decimate() в модели.
//
// Вход — поток valid/sof/sol/data: sof у первого пикселя кадра, sol у первого пикселя каждой
// строки. Позиция пикселя считается по этим признакам, поэтому точная ширина строки камеры
// знать не нужно. Выход — поток valid/sof/data, задержка 1 такт.
module frame_decimator #(
    parameter int unsigned DataW = 16,
    parameter int unsigned Factor = 4,
    parameter int unsigned OutWidth = 160,
    parameter int unsigned OutHeight = 120
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1

    input logic             valid_i,
    input logic             sof_i,
    input logic             sol_i,
    input logic [DataW-1:0] data_i,

    output logic             valid_o,
    output logic             sof_o,
    output logic [DataW-1:0] data_o
);

  localparam int unsigned SubW = (Factor > 1) ? $clog2(Factor) : 1;
  localparam int unsigned XW   = $clog2(OutWidth + 1);
  localparam int unsigned YW   = $clog2(OutHeight + 1);

  // Позиция предыдущего пикселя: номер квадрата (x_q, y_q) и место внутри него (xs_q, ys_q).
  logic [SubW-1:0] xs_q, ys_q, xs, ys;
  logic [XW-1:0] x_q, x;
  logic [YW-1:0] y_q, y;

  // Позиция текущего пикселя.
  always_comb begin
    xs = xs_q;
    ys = ys_q;
    x  = x_q;
    y  = y_q;
    if (sof_i) begin
      {xs, ys, x, y} = '0;
    end else if (sol_i) begin
      xs = '0;
      x  = '0;
      if (ys_q == SubW'(Factor - 1)) begin
        ys = '0;
        if (y_q != YW'(OutHeight)) y = y_q + 1'b1;  // дальше OutHeight не считаем
      end else begin
        ys = ys_q + 1'b1;
      end
    end else if (xs_q == SubW'(Factor - 1)) begin
      xs = '0;
      if (x_q != XW'(OutWidth)) x = x_q + 1'b1;
    end else begin
      xs = xs_q + 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      {xs_q, ys_q, x_q, y_q} <= '0;
      valid_o <= 1'b0;
      sof_o <= 1'b0;
    end else begin
      if (valid_i) begin
        xs_q <= xs;
        ys_q <= ys;
        x_q  <= x;
        y_q  <= y;
      end
      valid_o <= valid_i && xs == '0 && ys == '0 && x < XW'(OutWidth) && y < YW'(OutHeight);
      sof_o   <= valid_i && xs == '0 && ys == '0 && x == '0 && y == '0;
    end
    data_o <= data_i;
  end

endmodule
