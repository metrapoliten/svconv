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
    localparam int unsigned AddrW = $clog2(SrcWidth * SrcHeight)
) (
    input logic clk_i,  // пиксельная частота
    input logic rst_i,  // синхронный сброс, активный уровень 1

    output logic [AddrW-1:0] fb_addr_o,
    input  logic [      7:0] fb_data_i,

    output logic de_o,
    output logic [5:0] gray_o  // уровень серого, RGB666: один и тот же на R, G и B
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
      .SrcHeight(SrcHeight)
  ) u_reader (
      .clk_i    (clk_i),
      .de_i     (de),
      .x_i      (x),
      .y_i      (y),
      .fb_addr_o(fb_addr_o),
      .fb_data_i(fb_data_i),
      .de_o     (de_o),
      .gray_o   (gray_o)
  );

endmodule
