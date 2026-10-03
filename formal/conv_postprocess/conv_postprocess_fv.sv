`timescale 1ns / 1ps

// Формальная проверка conv_postprocess для всех значений суммы, сдвига и режима.
//
// Свойство записано независимо от формулы в RTL — через неравенства. Пусть v = |сумма| (или
// сумма, если abs_i = 0), d = 2^shift. Тогда результат p — округление v/d до ближайшего
// целого (половина вверх), ограниченное диапазоном 0..255:
//   0 < p < 255:  p*d - d/2 <= v < p*d + d/2      (при d = 1: v = p)
//   p = 0:        v < d/2                         (при d = 1: v <= 0)
//   p = 255:      v >= 255*d - d/2                (при d = 1: v >= 255)
module conv_postprocess_fv (
    input logic signed [21:0] sum_i,
    input logic        [ 3:0] shift_i,
    input logic               abs_i
);

  localparam int unsigned AccW = 22;

  logic [7:0] pixel;

  conv_postprocess #(
      .AccW(AccW)
  ) dut (
      .sum_i  (sum_i),
      .shift_i(shift_i),
      .abs_i  (abs_i),
      .pixel_o(pixel)
  );

  // Вычисления с запасом разрядности: 40 бит со знаком.
  logic signed [39:0] v, d, half, p;

  always_comb begin
    v    = (abs_i && sum_i < 0) ? -(40'(sum_i)) : 40'(sum_i);
    d    = 40'(1) << shift_i;
    half = (shift_i == 0) ? 40'(0) : (d >>> 1);
    p    = 40'(pixel);

    if (pixel > 0 && pixel < 255) begin
      if (shift_i == 0)
        assert (v == p);
        else assert (p * d - half <= v && v < p * d + half);
    end
    if (pixel == 0) begin
      if (shift_i == 0)
        assert (v <= 0);
        else assert (v < half);
    end
    if (pixel == 255) begin
      if (shift_i == 0)
        assert (v >= 255);
        else assert (v >= 255 * d - half);
    end
  end

endmodule
