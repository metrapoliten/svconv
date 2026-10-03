`timescale 1ns / 1ps

// Вывод кадра SrcWidth×SrcHeight из кадрового буфера на RGB-дисплей с целочисленным
// увеличением Scale и по центру экрана; вне картинки — чёрный цвет. Пиксели в оттенках серого
// выводятся как RGB565 (R = G = B).
//
// По координатам от video_timing вычисляется адрес в буфере: (y - OffY) / Scale * SrcWidth +
// (x - OffX) / Scale. Деление — на константу: для степеней двойки это просто сдвиг.
// Чтение буфера занимает такт, поэтому синхросигналы задерживаются на столько же, чтобы
// цвет и синхросигналы на выходе относились к одному пикселю.
module lcd_frame_reader #(
    parameter int unsigned HActive = 480,
    parameter int unsigned VActive = 272,
    parameter int unsigned HW = 10,  // разрядность x_i
    parameter int unsigned VW = 9,  // разрядность y_i
    parameter int unsigned SrcWidth = 160,
    parameter int unsigned SrcHeight = 120,
    parameter int unsigned Scale = 2,
    localparam int unsigned AddrW = $clog2(SrcWidth * SrcHeight)
) (
    input logic clk_i,  // пиксельная частота

    // Выходы video_timing.
    input logic          hsync_i,
    input logic          vsync_i,
    input logic          de_i,
    input logic [HW-1:0] x_i,
    input logic [VW-1:0] y_i,

    // Чтение кадрового буфера.
    output logic [AddrW-1:0] fb_addr_o,
    input  logic [      7:0] fb_data_i,

    // Выход на дисплей.
    output logic       hsync_o,
    output logic       vsync_o,
    output logic       de_o,
    output logic [4:0] r_o,
    output logic [5:0] g_o,
    output logic [4:0] b_o
);

  localparam int unsigned OutW = SrcWidth * Scale;
  localparam int unsigned OutH = SrcHeight * Scale;
  localparam int unsigned OffX = (HActive - OutW) / 2;
  localparam int unsigned OffY = (VActive - OutH) / 2;

  if (OutW > HActive || OutH > VActive) begin : g_check_size
    $error("lcd_frame_reader: scaled image does not fit the display");
  end

  // Стадия 1: адрес чтения (комбинационно из координат) и признак «внутри картинки».
  logic in_image;
  logic [AddrW-1:0] addr;

  always_comb begin
    in_image = (int'(x_i) >= int'(OffX)) && (int'(x_i) < int'(OffX + OutW)) &&
             (int'(y_i) >= int'(OffY)) && (int'(y_i) < int'(OffY + OutH));
    addr = in_image ?
        AddrW'((int'(y_i) - int'(OffY)) / int'(Scale) * int'(SrcWidth) +
               (int'(x_i) - int'(OffX)) / int'(Scale)) : '0;
  end

  assign fb_addr_o = addr;

  // Стадия 2: данные буфера готовы; синхросигналы и признак задержаны на такт.
  logic hsync_q, vsync_q, de_q, in_image_q;

  always_ff @(posedge clk_i) begin
    hsync_q    <= hsync_i;
    vsync_q    <= vsync_i;
    de_q       <= de_i;
    in_image_q <= in_image && de_i;
  end

  always_ff @(posedge clk_i) begin
    hsync_o <= hsync_q;
    vsync_o <= vsync_q;
    de_o    <= de_q;
    r_o     <= in_image_q ? fb_data_i[7:3] : '0;
    g_o     <= in_image_q ? fb_data_i[7:2] : '0;
    b_o     <= in_image_q ? fb_data_i[7:3] : '0;
  end

endmodule
