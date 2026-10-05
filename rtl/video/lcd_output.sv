`timescale 1ns / 1ps

// Вывод кадрового буфера на RGB-LCD: генератор таймингов (video_timing) и чтение кадра с
// увеличением и центрированием (lcd_frame_reader). Работает на пиксельной частоте дисплея.
// Тайминги — из документации на дисплей; для SH500Q01Z — в boards/mega138k/camera_lcd_top.sv.
module lcd_output #(
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
    parameter int unsigned SrcWidth = 160,
    parameter int unsigned SrcHeight = 120,
    parameter int unsigned Scale = 2,
    parameter int unsigned RBits = 5,  // формат цвета: RGB565 — 5/6/5, RGB666 — 6/6/6
    parameter int unsigned GBits = 6,
    parameter int unsigned BBits = 5,
    localparam int unsigned AddrW = $clog2(SrcWidth * SrcHeight)
) (
    input logic clk_i,  // пиксельная частота
    input logic rst_i,  // синхронный сброс, активный уровень 1

    output logic [AddrW-1:0] fb_addr_o,
    input  logic [      7:0] fb_data_i,

    output logic             hsync_o,
    output logic             vsync_o,
    output logic             de_o,
    output logic [RBits-1:0] r_o,
    output logic [GBits-1:0] g_o,
    output logic [BBits-1:0] b_o
);

  localparam int unsigned HW = $clog2(HActive + HFront + HSync + HBack);
  localparam int unsigned VW = $clog2(VActive + VFront + VSync + VBack);

  logic hsync, vsync, de;
  logic [HW-1:0] x;
  logic [VW-1:0] y;

  video_timing #(
      .HActive (HActive),
      .HFront  (HFront),
      .HSync   (HSync),
      .HBack   (HBack),
      .VActive (VActive),
      .VFront  (VFront),
      .VSync   (VSync),
      .VBack   (VBack),
      .HSyncPol(HSyncPol),
      .VSyncPol(VSyncPol)
  ) u_timing (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .hsync_o(hsync),
      .vsync_o(vsync),
      .de_o   (de),
      .x_o    (x),
      .y_o    (y)
  );

  lcd_frame_reader #(
      .HActive  (HActive),
      .VActive  (VActive),
      .HW       (HW),
      .VW       (VW),
      .SrcWidth (SrcWidth),
      .SrcHeight(SrcHeight),
      .Scale    (Scale),
      .RBits    (RBits),
      .GBits    (GBits),
      .BBits    (BBits)
  ) u_reader (
      .clk_i    (clk_i),
      .hsync_i  (hsync),
      .vsync_i  (vsync),
      .de_i     (de),
      .x_i      (x),
      .y_i      (y),
      .fb_addr_o(fb_addr_o),
      .fb_data_i(fb_data_i),
      .hsync_o  (hsync_o),
      .vsync_o  (vsync_o),
      .de_o     (de_o),
      .r_o      (r_o),
      .g_o      (g_o),
      .b_o      (b_o)
  );

endmodule
