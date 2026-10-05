`timescale 1ns / 1ps

// Вывод кадрового буфера на RGB-LCD в режиме DE: генератор таймингов (video_timing) и чтение
// кадра с центрированием (lcd_frame_reader). Работает на пиксельной частоте дисплея.
// Тайминги — из документации на дисплей; для SH500Q01Z — в boards/mega138k/camera_lcd_top.sv.
module lcd_output #(
    parameter int unsigned HActive = 800,
    parameter int unsigned HBlank = 392,
    parameter int unsigned VActive = 480,
    parameter int unsigned VBlank = 53,
    parameter int unsigned SrcWidth = 640,
    parameter int unsigned SrcHeight = 480,
    parameter int unsigned RBits = 6,  // формат цвета: RGB565 — 5/6/5, RGB666 — 6/6/6
    parameter int unsigned GBits = 6,
    parameter int unsigned BBits = 6,
    localparam int unsigned AddrW = $clog2(SrcWidth * SrcHeight)
) (
    input logic clk_i,  // пиксельная частота
    input logic rst_i,  // синхронный сброс, активный уровень 1

    output logic [AddrW-1:0] fb_addr_o,
    input  logic [      7:0] fb_data_i,

    output logic             de_o,
    output logic [RBits-1:0] r_o,
    output logic [GBits-1:0] g_o,
    output logic [BBits-1:0] b_o
);

  localparam int unsigned HW = $clog2(HActive + HBlank);
  localparam int unsigned VW = $clog2(VActive + VBlank);

  logic de;
  logic [HW-1:0] x;
  logic [VW-1:0] y;

  video_timing #(
      .HActive(HActive),
      .HBlank (HBlank),
      .VActive(VActive),
      .VBlank (VBlank)
  ) u_timing (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .de_o (de),
      .x_o  (x),
      .y_o  (y)
  );

  lcd_frame_reader #(
      .HActive  (HActive),
      .VActive  (VActive),
      .HW       (HW),
      .VW       (VW),
      .SrcWidth (SrcWidth),
      .SrcHeight(SrcHeight),
      .RBits    (RBits),
      .GBits    (GBits),
      .BBits    (BBits)
  ) u_reader (
      .clk_i    (clk_i),
      .de_i     (de),
      .x_i      (x),
      .y_i      (y),
      .fb_addr_o(fb_addr_o),
      .fb_data_i(fb_data_i),
      .de_o     (de_o),
      .r_o      (r_o),
      .g_o      (g_o),
      .b_o      (b_o)
  );

endmodule
