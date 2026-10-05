`timescale 1ns / 1ps

// Стенд camera_uart на Tang Primer 20K + Dock: камера OV7670 (модуль 2×9, на проводах) ->
// прореживание до 160×120 -> серый -> цепочка свёрток; кадры по запросу передаются на
// компьютер через UART отладчика BL702 (115200 бод, 8N1). Дисплей не нужен.
//
// Подключение камеры — по порядку выводов модуля 2×9 (1 3V3, 2 GND, 3 SIOC, 4 SIOD, 5 VSYNC,
// 6 HREF, 7 PCLK, 8 XCLK, 9..16 D7..D0, 17 RESET, 18 PWDN), с двумя отступлениями: PCLK — только
// на J14-10 (T7, из выводов гребёнок только он — глобальный тактовый вход GCLKT_3, UG110), а
// J14-5/6 (выводы конфигурации ПЛИС, J14-6 идёт ещё и на вход WS2812 дока) — под RESET и PWDN,
// которые камера только принимает. У гребёнок дока контакты 1, 2 — +3,3 В, 3, 4 — земля.
//   J12: 1 3V3, 3 GND, 5 SIOC, 6 SIOD, 7 VSYNC, 8 HREF, 9 D2, 10 XCLK, 11 D7, 12 D6
//   J14: 5 RESET, 6 PWDN, 7 D5, 8 D4, 9 D3, 10 PCLK, 11 D1, 12 D0
// XCLK — генератор 27 МГц платы.
//
// Где это на доке (по iBOM ревизии 3709): вдоль края с плоскими разъёмами в ряд стоят четыре
// гребёнки 2×6 — J5, J6, J12, J14 слева направо (кнопки — у левого края); J12 — под 24-контактным
// разъёмом камеры, J14 — крайняя правая, под маленьким разъёмом микрофонной решётки. Контакт 1
// (квадратная площадка) — слева, в ряду, дальнем от края платы; контакт 2 — рядом с ним, ближе к
// краю; далее 3, 4 и т. д. вправо.
//
// Светодиоды дока (по шелкографии, горят при 0 на выводе):
//   LED2 — мигает раз в секунду, LED3 — камера настроена, LED4 — переключается на каждом
//   кадре камеры, LED5 — стенд выполняет команду.
module camera_uart_top #(
    parameter int unsigned ClkFreq = 27_000_000,
    parameter int unsigned Baud    = 115_200
) (
    input  logic clk27_i,
    input  logic uart_rx_i,
    output logic uart_tx_o,

    inout  wire        cam_scl_io,
    inout  wire        cam_sda_io,
    input  logic       cam_pclk_i,
    input  logic       cam_vsync_i,
    input  logic       cam_href_i,
    input  logic [7:0] cam_data_i,
    output logic       cam_xclk_o,
    output logic       cam_rst_n_o,
    output logic       cam_pwdn_o,

    output logic [3:0] led_n_o  // LED2..LED5, активный 0
);

  // Сброс после включения: rst = 1 первые 2^4 тактов (начальные значения задаёт битстрим).
  logic [3:0] por_cnt_q = '0;
  logic       rst;

  always_ff @(posedge clk27_i) begin
    if (por_cnt_q != '1) por_cnt_q <= por_cnt_q + 1'b1;
  end
  assign rst = (por_cnt_q != '1);

  // --- Камера: XCLK и настройка по SCCB ---------------------------------------------------
  assign cam_xclk_o = clk27_i;

  logic sioc_oe, siod_oe, cam_ready;

  // SCCB — 25 кГц: SIOC/SIOD подтянуты только внутренней подтяжкой ПЛИС (~100 мкА, около
  // 33 кОм), и на проводах фронт нарастает микросекунды; при 25 кГц SIOC держится высоким 20 мкс.
  // Нижнего предела частоты у SCCB нет; настройка камеры длится ~115 мс вместо ~45.
  ov7670_init #(
      .ClkFreq (ClkFreq),
      .SccbFreq(25_000)
  ) u_cam_init (
      .clk_i      (clk27_i),
      .rst_i      (rst),
      .cam_rst_n_o(cam_rst_n_o),
      .cam_pwdn_o (cam_pwdn_o),
      .sioc_oe_o  (sioc_oe),
      .siod_oe_o  (siod_oe),
      .done_o     (cam_ready)
  );

  // Открытый сток: ПЛИС только прижимает линии к нулю (подтяжка — внутренняя, см. .cst).
  assign cam_scl_io = sioc_oe ? 1'b0 : 1'bz;
  assign cam_sda_io = siod_oe ? 1'b0 : 1'bz;

  // --- Сброс домена PCLK ------------------------------------------------------------------
  // Сброс в домен PCLK переходит через синхронизатор; после загрузки ПЛИС домен уже в сбросе.
  logic rst_pclk;

  level_sync #(
      .Init(1'b1)
  ) u_rst_pclk_sync (
      .clk_i(cam_pclk_i),
      .d_i  (rst),
      .q_o  (rst_pclk)
  );

  // --- Стенд --------------------------------------------------------------------------------
  // Номера ядер — порядок KERNEL_ROM_ORDER в модели: 0 identity, 1 gauss5, 2 log5.
  localparam int unsigned SelW = 2;
  localparam logic [3*SelW-1:0] ChainBlurBlurEdges = {2'd2, 2'd1, 2'd1};

  logic busy, frame;

  camera_uart #(
      .Width     (160),
      .Height    (120),
      .Factor    (4),
      .K         (5),
      .NumStages (3),
      .NumKernels(3),
      .KernelFile("kernels.hex"),
      .SelW      (SelW),
      .ClkFreq   (ClkFreq),
      .Baud      (Baud),
      .DefaultEn (3'b111),
      .DefaultSel(ChainBlurBlurEdges)
  ) u_bench (
      .clk_i      (clk27_i),
      .rst_i      (rst),
      .uart_rx_i  (uart_rx_i),
      .uart_tx_o  (uart_tx_o),
      .busy_o     (busy),
      .pclk_i     (cam_pclk_i),
      .rst_pclk_i (rst_pclk),
      .cam_vsync_i(cam_vsync_i),
      .cam_href_i (cam_href_i),
      .cam_data_i (cam_data_i),
      .ready_o    (),
      .frame_o    (frame)
  );

  // --- Светодиоды -------------------------------------------------------------------------
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

  assign led_n_o = ~{busy, frame, cam_ready, blink_q};

endmodule
