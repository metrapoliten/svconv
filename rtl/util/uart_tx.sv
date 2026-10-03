`timescale 1ns / 1ps

// UART-передатчик: 8 бит данных, без контроля чётности, 1 стоп-бит (8N1).
//
// Протокол: байт принимается, когда valid_i && ready_o на фронте clk_i.
// Линия в покое — логическая 1; кадр: старт-бит (0), биты 0..7 (младший первым), стоп-бит (1).
module uart_tx #(
    parameter int unsigned ClkFreq = 27_000_000,  // частота clk_i, Гц
    parameter int unsigned Baud    = 115_200      // скорость, бит/с
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1
    input logic [7:0] data_i,
    input logic valid_i,
    output logic ready_o,
    output logic tx_o
);

  // Тактов на бит, округлено до ближайшего целого (27 МГц / 115200 -> 234).
  localparam int unsigned ClksPerBit = (ClkFreq + Baud / 2) / Baud;
  // При ClksPerBit = 1 $clog2 даёт 0, а счётчику нужен хотя бы один бит.
  localparam int unsigned CntWidth = (ClksPerBit <= 1) ? 1 : $clog2(ClksPerBit);
  localparam logic [CntWidth-1:0] CntMax = CntWidth'(ClksPerBit - 1);

  // Сдвиговый регистр кадра: {стоп, данные[7:0], старт}; выдаётся младшим битом вперёд.
  logic [9:0] shift_q;
  // Сколько бит кадра ещё осталось передать; 0 — передатчик свободен.
  logic [3:0] bits_left_q;
  logic [CntWidth-1:0] clk_cnt_q;

  assign ready_o = (bits_left_q == 0);

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      shift_q     <= '1;
      bits_left_q <= '0;
      clk_cnt_q   <= '0;
      tx_o        <= 1'b1;
    end else if (ready_o) begin
      tx_o <= 1'b1;
      if (valid_i) begin
        shift_q     <= {1'b1, data_i, 1'b0};
        bits_left_q <= 4'd10;
        clk_cnt_q   <= '0;
      end
    end else begin
      // Текущий бит держится на линии ClksPerBit тактов.
      tx_o <= shift_q[0];
      if (clk_cnt_q == CntMax) begin
        clk_cnt_q   <= '0;
        shift_q     <= {1'b1, shift_q[9:1]};
        bits_left_q <= bits_left_q - 1'b1;
      end else begin
        clk_cnt_q <= clk_cnt_q + 1'b1;
      end
    end
  end

endmodule
