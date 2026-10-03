`timescale 1ns / 1ps

// Постобработка суммы свёртки (комбинационная): модуль (если abs_i), деление на 2^shift_i
// с округлением половины вверх и насыщение до 0..255. Совпадает с postprocess() в модели.
module conv_postprocess #(
    parameter int unsigned AccW = 22  // разрядность суммы
) (
    input  logic signed [AccW-1:0] sum_i,
    input  logic        [     3:0] shift_i,
    input  logic                   abs_i,
    output logic        [     7:0] pixel_o
);

  // На разряд шире суммы: модуль минимального значения и прибавка для округления не
  // переполняются.
  localparam int unsigned W = AccW + 1;
  logic signed [W-1:0] mag, rounded, scaled;

  always_comb begin
    mag = (abs_i && sum_i < 0) ? -(W'(sum_i)) : W'(sum_i);
    rounded = (shift_i == 0) ? mag : mag + (W'(1) <<< (shift_i - 1));
    scaled = rounded >>> shift_i;
    if (scaled < 0) pixel_o = 8'd0;
    else if (scaled > 255) pixel_o = 8'd255;
    else pixel_o = scaled[7:0];
  end

endmodule
