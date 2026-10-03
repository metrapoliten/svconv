`timescale 1ns / 1ps

// Генератор видеотаймингов для параллельного RGB-интерфейса (RGB-LCD, VGA).
//
// Строка: HActive видимых пикселей, затем передняя площадка HFront, синхроимпульс HSync и
// задняя площадка HBack; кадр устроен так же по строкам (VActive, VFront, VSync, VBack).
// Полярность синхроимпульсов задаётся HSyncPol/VSyncPol (1 — импульс единицей).
//
// x_o, y_o — координаты текущего пикселя внутри видимой области (имеют смысл при de_o = 1).
// Все выходы регистровые и относятся к одному и тому же пикселю.
module video_timing #(
    parameter int unsigned HActive = 480,
    parameter int unsigned HFront = 2,
    parameter int unsigned HSync = 41,
    parameter int unsigned HBack = 2,
    parameter int unsigned VActive = 272,
    parameter int unsigned VFront = 2,
    parameter int unsigned VSync = 10,
    parameter int unsigned VBack = 2,
    parameter bit HSyncPol = 1'b0,
    parameter bit VSyncPol = 1'b0,
    localparam int unsigned HTotal = HActive + HFront + HSync + HBack,
    localparam int unsigned VTotal = VActive + VFront + VSync + VBack,
    localparam int unsigned HW = $clog2(HTotal),
    localparam int unsigned VW = $clog2(VTotal)
) (
    input logic clk_i,  // пиксельная частота
    input logic rst_i,  // синхронный сброс, активный уровень 1

    output logic          hsync_o,
    output logic          vsync_o,
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
    if (rst_i) begin
      hsync_o <= ~HSyncPol;
      vsync_o <= ~VSyncPol;
      de_o    <= 1'b0;
    end else begin
      hsync_o <= (h_q >= HW'(HActive + HFront) && h_q < HW'(HActive + HFront + HSync)) ?
          HSyncPol : ~HSyncPol;
      vsync_o <= (v_q >= VW'(VActive + VFront) && v_q < VW'(VActive + VFront + VSync)) ?
          VSyncPol : ~VSyncPol;
      de_o <= (h_q < HW'(HActive)) && (v_q < VW'(VActive));
    end
    x_o <= h_q;
    y_o <= v_q;
  end

endmodule
