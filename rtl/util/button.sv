`timescale 1ns / 1ps

// Кнопка: синхронизация асинхронного входа, подавление дребезга и импульс на нажатие.
// Состояние кнопки меняется, только если вход не менялся StableClks тактов подряд.
module button #(
    parameter int unsigned StableClks,  // столько тактов вход должен не меняться (10 мс — обычно)
    parameter bit ActiveLow = 1'b1  // 1 — нажатая кнопка замыкает вход на землю
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1
    input logic btn_i,
    output logic pressed_o,  // кнопка нажата (после подавления дребезга)
    output logic press_o  // импульс в такт нажатия
);

  localparam int unsigned CntW = $clog2(StableClks + 1);

  logic raw;
  logic [CntW-1:0] cnt_q;

  level_sync u_sync (
      .clk_i(clk_i),
      .d_i  (btn_i ^ ActiveLow),
      .q_o  (raw)
  );

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      cnt_q     <= '0;
      pressed_o <= 1'b0;
      press_o   <= 1'b0;
    end else begin
      press_o <= 1'b0;
      if (raw == pressed_o) begin
        cnt_q <= '0;
      end else if (cnt_q == CntW'(StableClks - 1)) begin
        cnt_q     <= '0;
        pressed_o <= raw;
        press_o   <= raw;
      end else begin
        cnt_q <= cnt_q + 1'b1;
      end
    end
  end

endmodule
