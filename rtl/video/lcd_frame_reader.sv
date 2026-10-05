`timescale 1ns / 1ps

// Вывод кадра SrcWidth×SrcHeight из кадрового буфера на RGB-дисплей по центру экрана; вне
// картинки — чёрный цвет. Выход — уровень серого: 6 старших бит пикселя (дисплей подключён в
// формате RGB666, один и тот же уровень подаётся на R, G и B).
//
// По координатам от video_timing вычисляется адрес в буфере: (y - OffY) * SrcWidth + (x - OffX).
// Чтение буфера занимает такт, поэтому DE задерживается на столько же, чтобы цвет и DE на выходе
// относились к одному пикселю.
module lcd_frame_reader #(
    parameter int unsigned HActive = 800,
    parameter int unsigned VActive = 480,
    parameter int unsigned HW = 11,  // разрядность x_i
    parameter int unsigned VW = 10,  // разрядность y_i
    parameter int unsigned SrcWidth = 640,
    parameter int unsigned SrcHeight = 480,
    localparam int unsigned AddrW = $clog2(SrcWidth * SrcHeight)
) (
    input logic clk_i,  // пиксельная частота

    // Выходы video_timing.
    input logic          de_i,
    input logic [HW-1:0] x_i,
    input logic [VW-1:0] y_i,

    // Чтение кадрового буфера.
    output logic [AddrW-1:0] fb_addr_o,
    input  logic [      7:0] fb_data_i,

    // Выход на дисплей.
    output logic       de_o,
    output logic [5:0] gray_o
);

  localparam int unsigned OffX = (HActive - SrcWidth) / 2;
  localparam int unsigned OffY = (VActive - SrcHeight) / 2;

  if (SrcWidth > HActive || SrcHeight > VActive) begin : g_check_size
    $error("lcd_frame_reader: the image does not fit the display");
  end

  // Стадия 1: адрес чтения (комбинационно из координат) и признак «внутри картинки».
  logic in_image;
  logic [AddrW-1:0] addr;

  always_comb begin
    in_image = (int'(x_i) >= int'(OffX)) && (int'(x_i) < int'(OffX + SrcWidth)) &&
             (int'(y_i) >= int'(OffY)) && (int'(y_i) < int'(OffY + SrcHeight));
    addr = in_image ?
        AddrW'((int'(y_i) - int'(OffY)) * int'(SrcWidth) + (int'(x_i) - int'(OffX))) : '0;
  end

  assign fb_addr_o = addr;

  // Стадия 2: данные буфера готовы; DE и признак задержаны на такт.
  logic de_q, in_image_q;

  always_ff @(posedge clk_i) begin
    de_q       <= de_i;
    in_image_q <= in_image && de_i;
  end

  always_ff @(posedge clk_i) begin
    de_o   <= de_q;
    gray_o <= in_image_q ? fb_data_i[7:2] : '0;
  end

endmodule
