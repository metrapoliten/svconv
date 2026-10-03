`timescale 1ns / 1ps

// Стенд uart_bench на Tang Primer 20K + Dock: цепочка свёрток на тестовом изображении из ПЗУ,
// управление и выгрузка кадров по UART через отладчик BL702 (115200 бод, 8N1).
//
// Светодиоды дока (по шелкографии, горят при 0 на выводе):
//   LED2 — мигает раз в секунду (прошивка работает), LED3 — ядра загружены,
//   LED4 — стенд выполняет команду, LED5 — не используется.
module uart_bench_top #(
    parameter int unsigned ClkFreq = 27_000_000,
    parameter int unsigned Baud    = 115_200
) (
    input  logic       clk27_i,    // генератор 27 МГц
    input  logic       uart_rx_i,  // от BL702
    output logic       uart_tx_o,  // к BL702
    output logic [3:0] led_n_o     // LED2..LED5, активный уровень 0
);

  // Сброс после включения: rst = 1 первые 2^4 тактов (начальные значения задаёт битстрим).
  logic [3:0] por_cnt_q = '0;
  logic       rst;

  always_ff @(posedge clk27_i) begin
    if (por_cnt_q != '1) por_cnt_q <= por_cnt_q + 1'b1;
  end
  assign rst = (por_cnt_q != '1);

  // Номера ядер — порядок KERNEL_ROM_ORDER в модели: 0 identity, 1 gauss5, 2 log5.
  localparam int unsigned SelW = 2;
  localparam logic [3*SelW-1:0] ChainBlurBlurEdges = {2'd2, 2'd1, 2'd1};

  logic ready, busy;

  uart_bench #(
      .Width     (160),
      .Height    (120),
      .K         (5),
      .NumStages (3),
      .NumKernels(3),
      .ClkFreq   (ClkFreq),
      .Baud      (Baud),
      .ImageFile ("image.hex"),
      .KernelFile("kernels.hex"),
      .SelW      (SelW),
      .DefaultEn (3'b111),
      .DefaultSel(ChainBlurBlurEdges)
  ) u_bench (
      .clk_i    (clk27_i),
      .rst_i    (rst),
      .uart_rx_i(uart_rx_i),
      .uart_tx_o(uart_tx_o),
      .ready_o  (ready),
      .busy_o   (busy)
  );

  // Мигание раз в секунду.
  localparam int unsigned HalfSec = ClkFreq / 2;
  logic [$clog2(HalfSec)-1:0] blink_cnt_q;
  logic                       blink_q;

  always_ff @(posedge clk27_i) begin
    if (rst) begin
      blink_cnt_q <= '0;
      blink_q     <= 1'b0;
    end else if (blink_cnt_q == $bits(blink_cnt_q)'(HalfSec - 1)) begin
      blink_cnt_q <= '0;
      blink_q     <= ~blink_q;
    end else begin
      blink_cnt_q <= blink_cnt_q + 1'b1;
    end
  end

  assign led_n_o = ~{1'b0, busy, ready, blink_q};

endmodule
