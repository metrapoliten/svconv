`timescale 1ns / 1ps

// Кнопка: синхронизация асинхронного входа, подавление дребезга и импульс на нажатие.
// Состояние кнопки меняется, только если вход не менялся StableClks тактов подряд.
module button #(
    parameter int unsigned StableClks = 270_000,  // 10 мс при 27 МГц
    parameter bit ActiveLow = 1'b1  // 1 — нажатая кнопка замыкает вход на землю
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1
    input logic btn_i,
    output logic pressed_o,  // кнопка нажата (после подавления дребезга)
    output logic press_o  // импульс в такт нажатия
);

  localparam int unsigned CntW = $clog2(StableClks + 1);

  logic [1:0] sync_q;
  logic raw;
  logic [CntW-1:0] cnt_q;

  always_ff @(posedge clk_i) sync_q <= {sync_q[0], btn_i ^ ActiveLow};
  assign raw = sync_q[1];

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
