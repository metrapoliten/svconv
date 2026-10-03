`timescale 1ns / 1ps

// UART-приёмник 8N1 (пара к uart_tx).
//
// Линия rx_i асинхронна, поэтому сначала проходит через два триггера синхронизации.
// По спаду (старт-бит) приёмник ждёт полбита, проверяет, что линия всё ещё 0, затем выбирает
// 8 бит данных и стоп-бит в серединах битов. Принятый байт выдаётся импульсом valid_o длиной
// в такт; байт с неверным стоп-битом (ошибка кадра) отбрасывается.
module uart_rx #(
    parameter int unsigned ClkFreq = 27_000_000,  // частота clk_i, Гц
    parameter int unsigned Baud    = 115_200      // скорость, бит/с
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1
    input logic rx_i,
    output logic [7:0] data_o,
    output logic valid_o
);

  // Тактов на бит, округлено до ближайшего целого (27 МГц / 115200 -> 234).
  localparam int unsigned ClksPerBit = (ClkFreq + Baud / 2) / Baud;
  // При ClksPerBit = 1 $clog2 даёт 0, а счётчику нужен хотя бы один бит.
  localparam int unsigned CntWidth = (ClksPerBit <= 1) ? 1 : $clog2(ClksPerBit);
  localparam logic [CntWidth-1:0] CntMax = CntWidth'(ClksPerBit - 1);
  localparam logic [CntWidth-1:0] CntHalf = CntWidth'((ClksPerBit - 1) / 2);

  // Синхронизатор: начальное значение 1 — линия в покое.
  logic [1:0] sync_q = 2'b11;
  logic       rx;

  always_ff @(posedge clk_i) sync_q <= {sync_q[0], rx_i};
  assign rx = sync_q[1];

  typedef enum logic [1:0] {
    Idle,
    Start,
    Data,
    Stop
  } state_e;

  state_e state_q;
  logic [CntWidth-1:0] clk_cnt_q;
  logic [2:0] bit_idx_q;
  logic [7:0] shift_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q   <= Idle;
      clk_cnt_q <= '0;
      bit_idx_q <= '0;
      valid_o   <= 1'b0;
    end else begin
      valid_o <= 1'b0;
      unique case (state_q)
        Idle: begin
          clk_cnt_q <= '0;
          if (!rx) state_q <= Start;
        end
        // Середина старт-бита: если линия вернулась в 1, это была помеха.
        Start: begin
          if (clk_cnt_q == CntHalf) begin
            clk_cnt_q <= '0;
            bit_idx_q <= '0;
            if (rx) state_q <= Idle;
            else state_q <= Data;
          end else begin
            clk_cnt_q <= clk_cnt_q + 1'b1;
          end
        end
        // Отсчитываем целый бит от середины предыдущего — попадаем в середину следующего.
        Data: begin
          if (clk_cnt_q == CntMax) begin
            clk_cnt_q <= '0;
            shift_q   <= {rx, shift_q[7:1]};
            bit_idx_q <= bit_idx_q + 1'b1;
            if (bit_idx_q == 3'd7) state_q <= Stop;
          end else begin
            clk_cnt_q <= clk_cnt_q + 1'b1;
          end
        end
        Stop: begin
          if (clk_cnt_q == CntMax) begin
            state_q <= Idle;
            valid_o <= rx;  // стоп-бит должен быть 1
          end else begin
            clk_cnt_q <= clk_cnt_q + 1'b1;
          end
        end
        default: state_q <= Idle;
      endcase
    end
  end

  assign data_o = shift_q;

endmodule
