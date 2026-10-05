`timescale 1ns / 1ps

// Камера OV7670 -> цепочка свёрток (640×480) -> дисплей 5" 800×480 SH500Q01Z на
// Tang Mega 138K Pro Dock.
//
// Тактовые сигналы:
//   clk50   — генератор платы 50 МГц: настройка камеры, кнопка, светодиоды;
//   PCLK    — от камеры (XCLK = 25 МГц от PLL): захват и обработка;
//   lcd_clk — пиксельная частота дисплея 35 МГц от PLL.
//
// Кадр камеры обрабатывается в полном разрешении 640×480 (памяти Mega 138K для этого хватает)
// и выводится по центру экрана 800×480. Тайминги дисплея (только DE), частота
// 35 МГц и неинвертированный тактовый сигнал дисплея — как в примере Sipeed
// TangMega-138KPro-example/rgb_screen/800_480_screen; тайминги укладываются в допуски
// контроллера панели ILI6122 (см. ниже). Цвет — RGB666 (6 старших бит каждого
// канала выведены на разъём дока), R = G = B = оттенок серого.
//
// Камера OV7670 — модуль 2×9 на проводах «мама–папа» к гнёздам PMOD1 (J24) и PMOD2 (J26) дока,
// по порядку выводов модуля (таблица — в camera_lcd.cst):
//   PMOD1: 1 3V3, 3 GND, 5 SIOC, 6 SIOD, 7 VSYNC, 8 HREF, 9 PCLK, 10 XCLK, 11 D7, 12 D6
//   PMOD2: 5 D5, 6 D4, 7 D3, 8 D2, 9 D1, 10 D0, 11 RESET, 12 PWDN
//
// Кнопка S1 переключает режим цепочки по кругу:
//   0 — размытие -> размытие -> границы (по заданию), 1 — без обработки,
//   2 — только размытие, 3 — только границы.
//
// Светодиоды дока (горят при 0): LED0 — мигает раз в секунду, LED1 — камера настроена,
// LED2 — переключается на каждом обработанном кадре, LED3 — ядра загружены,
// LED4, LED5 — номер режима.
// Параметры — для тестов (tests/camera_lcd_top_modes): по умолчанию — то, что загружается в плату.
module camera_lcd_top #(
    // Размер кадра камеры (OV7670 настроена на 640×480). Тест переключения режимов берёт
    // маленький кадр: обработка, переходы между доменами и управление те же, а моделировать
    // каждый кадр в десятки раз быстрее.
    parameter int unsigned CamWidth = 640,
    parameter int unsigned CamHeight = 480,
    // Частота SCCB, Гц (почему 25 кГц — см. u_cam_init). Тест повышает: иначе настройка камеры
    // занимает ~115 мс модельного времени.
    parameter int unsigned SccbFreq = 25_000,
    // Подавление дребезга кнопки: 10 мс при 50 МГц. Тест уменьшает, чтобы не моделировать
    // миллисекунды на каждое нажатие.
    parameter int unsigned BtnStableClks = 500_000
) (
    input logic clk50_i,
    input logic btn_n_i,  // кнопка S1, активный 0

    // Камера (гнёзда PMOD1/PMOD2 дока).
    inout wire cam_scl_io,
    inout wire cam_sda_io,
    input logic cam_pclk_i,
    input logic cam_vsync_i,
    input logic cam_href_i,
    input logic [7:0] cam_data_i,
    output logic cam_xclk_o,
    output logic cam_rst_n_o,
    output logic cam_pwdn_o,

    // Дисплей (RGB-разъём дока), режим DE.
    output logic       lcd_clk_o,
    output logic       lcd_de_o,
    output logic [5:0] lcd_r_o,
    output logic [5:0] lcd_g_o,
    output logic [5:0] lcd_b_o,

    output logic [5:0] led_n_o  // LED0..LED5, активный 0
);

  localparam int unsigned ClkFreq = 50_000_000;

  // --- Сброс после включения (домен clk50) ------------------------------------------------
  logic [3:0] por_cnt_q = '0;
  logic       rst;

  always_ff @(posedge clk50_i) begin
    if (por_cnt_q != '1) por_cnt_q <= por_cnt_q + 1'b1;
  end
  assign rst = (por_cnt_q != '1);

  // --- PLL: пиксельная частота дисплея и XCLK камеры ---------------------------------------
  // VCO = 50 МГц * MDIV / IDIV = 50 * 21 / 1 = 1050 МГц (FBDIV = 1);
  // CLKOUT0 = 1050 / 30 = 35 МГц (дисплей), CLKOUT1 = 1050 / 42 = 25 МГц (XCLK камеры).
  // Значения IDIV/FBDIV/MDIV/ODIV0 — из примера Sipeed 800_480_screen.
  logic lcd_clk, cam_clk, pll_lock;

  // Указаны только параметры, отличные от значений по умолчанию (те же в модели Gowin для
  // симуляции и в библиотеке синтеза). Входы подключены все: неподключённый вход в синтезе и
  // в модели ведёт себя по-разному (например, ENCLKx = 0 выключает выход).
  PLL #(
      .FCLKIN    ("50"),
      .IDIV_SEL  (1),
      .FBDIV_SEL (1),
      .MDIV_SEL  (21),
      .ODIV0_SEL (30),
      .ODIV1_SEL (42),
      .CLKOUT1_EN("TRUE")
  ) u_pll (
      .LOCK         (pll_lock),
      .CLKOUT0      (lcd_clk),
      .CLKOUT1      (cam_clk),
      .CLKOUT2      (),
      .CLKOUT3      (),
      .CLKOUT4      (),
      .CLKOUT5      (),
      .CLKOUT6      (),
      .CLKFBOUT     (),
      .CLKIN        (clk50_i),
      .CLKFB        (1'b0),
      .RESET        (1'b0),
      .PLLPWD       (1'b0),
      .RESET_I      (1'b0),
      .RESET_O      (1'b0),
      .FBDSEL       (6'b0),
      .IDSEL        (6'b0),
      .MDSEL        (7'b0),
      .MDSEL_FRAC   (3'b0),
      .ODSEL0       (7'b0),
      .ODSEL0_FRAC  (3'b0),
      .ODSEL1       (7'b0),
      .ODSEL2       (7'b0),
      .ODSEL3       (7'b0),
      .ODSEL4       (7'b0),
      .ODSEL5       (7'b0),
      .ODSEL6       (7'b0),
      .DT0          (4'b0),
      .DT1          (4'b0),
      .DT2          (4'b0),
      .DT3          (4'b0),
      .ICPSEL       (6'b0),
      .LPFRES       (3'b0),
      .LPFCAP       (2'b0),
      .PSSEL        (3'b0),
      .PSDIR        (1'b0),
      .PSPULSE      (1'b0),
      .ENCLK0       (1'b1),
      .ENCLK1       (1'b1),
      .ENCLK2       (1'b1),
      .ENCLK3       (1'b1),
      .ENCLK4       (1'b1),
      .ENCLK5       (1'b1),
      .ENCLK6       (1'b1),
      .SSCPOL       (1'b0),
      .SSCON        (1'b0),
      .SSCMDSEL     (7'b0),
      .SSCMDSEL_FRAC(3'b0)
  );

  // Сброс домена LCD — пока PLL не захватил частоту; снимается синхронно.
  logic [1:0] rst_lcd_q;

  always_ff @(posedge lcd_clk or negedge pll_lock) begin
    if (!pll_lock) rst_lcd_q <= 2'b11;
    else rst_lcd_q <= {rst_lcd_q[0], 1'b0};
  end

  // --- Камера: XCLK и настройка по SCCB ---------------------------------------------------
  assign cam_xclk_o = cam_clk;

  logic sioc_oe, siod_oe, cam_ready;

  // SCCB — 25 кГц: SIOC/SIOD подтянуты только внутренней подтяжкой ПЛИС (~100 мкА, около
  // 33 кОм), и на проводах фронт нарастает микросекунды; при 25 кГц SIOC держится высоким 20 мкс.
  // Нижнего предела частоты у SCCB нет; настройка камеры длится ~115 мс вместо ~45.
  ov7670_init #(
      .ClkFreq (ClkFreq),
      .SccbFreq(SccbFreq)
  ) u_cam_init (
      .clk_i      (clk50_i),
      .rst_i      (rst),
      .cam_rst_n_o(cam_rst_n_o),
      .cam_pwdn_o (cam_pwdn_o),
      .sioc_oe_o  (sioc_oe),
      .siod_oe_o  (siod_oe),
      .done_o     (cam_ready)
  );

  assign cam_scl_io = sioc_oe ? 1'b0 : 1'bz;
  assign cam_sda_io = siod_oe ? 1'b0 : 1'bz;

  // --- Режим цепочки: кнопка ----------------------------------------------------------------
  logic       btn_press;
  logic [1:0] mode_q;

  button #(
      .StableClks(BtnStableClks),
      .ActiveLow (1'b1)
  ) u_button (
      .clk_i    (clk50_i),
      .rst_i    (rst),
      .btn_i    (btn_n_i),
      .pressed_o(),
      .press_o  (btn_press)
  );

  always_ff @(posedge clk50_i) begin
    if (rst) mode_q <= '0;
    else if (btn_press) mode_q <= mode_q + 1'b1;
  end

  // В домен PCLK режим уходит кодом Грея (00, 01, 11, 10): при нажатии меняется ровно один
  // разряд, поэтому синхронизатор выдаёт либо старый режим, либо новый, но не их смесь. Код —
  // выход триггера, а настройка цепочки расшифровывается уже в домене PCLK.
  logic [1:0] mode_gray_q;

  always_ff @(posedge clk50_i) mode_gray_q <= mode_q ^ (mode_q >> 1);

  // Домен PCLK: синхронизация сброса и режима. После смены режима один-два выведенных кадра
  // могут быть смешанными (см. conv_pipeline.sv) — на экране это незаметно.
  // Домен PCLK стоит в сбросе, пока камера не настроена: во время её сброса и записи регистров
  // PCLK может останавливаться и сбоить, а kernel_rom загружает веса ядер только после сброса и
  // при смене ядра. На синхронизатор идёт выход триггера, а не комбинационное выражение.
  logic rst_cam_q = 1'b1;
  logic rst_pclk;
  logic [1:0] mode_gray_pclk, mode_pclk;

  always_ff @(posedge clk50_i) rst_cam_q <= rst || !cam_ready;

  level_sync #(
      .Init(1'b1)
  ) u_rst_pclk_sync (
      .clk_i(cam_pclk_i),
      .d_i  (rst_cam_q),
      .q_o  (rst_pclk)
  );

  level_sync #(
      .Width(2)
  ) u_mode_sync (
      .clk_i(cam_pclk_i),
      .d_i  (mode_gray_q),
      .q_o  (mode_gray_pclk)
  );

  assign mode_pclk = {mode_gray_pclk[1], ^mode_gray_pclk};

  // Ядро каждой стадии постоянное — как в режиме 0; режимы различаются только тем, какие
  // стадии включены (выключенная стадия пропускает кадр без изменений, её ядро не важно),
  // поэтому кнопка не перезагружает веса ядер.
  // Номера ядер — порядок KERNEL_ROM_ORDER в модели: 0 identity, 1 gauss5, 2 log5.
  localparam int unsigned SelW = 2;
  localparam logic [3*SelW-1:0] KernelSel = {2'd2, 2'd1, 2'd1};  // стадии 2, 1, 0
  logic [2:0] stage_en;

  always_comb begin
    unique case (mode_pclk)
      2'd0: stage_en = 3'b111;  // размытие, размытие, границы
      2'd1: stage_en = 3'b000;  // без обработки
      2'd2: stage_en = 3'b001;  // только размытие
      default: stage_en = 3'b100;  // только границы
    endcase
  end

  // --- Обработка и вывод ------------------------------------------------------------------
  logic pipe_ready, frame;
  logic lcd_de;
  logic [5:0] lcd_gray;

  camera_display #(
      .Width     (CamWidth),
      .Height    (CamHeight),
      .K         (5),
      .NumStages (3),
      .NumKernels(3),
      .KernelFile("kernels.hex"),
      .SelW      (SelW),
      // Тайминги — как в примере Sipeed: строка 800 + 392 такта гашения, кадр 480 + 53 строки.
      // Допуски ILI6122 (800×480): строка 862..1200 тактов (здесь 1192), кадр 510..650 строк
      // (здесь 533), частота до 50 МГц (здесь 35) — около 55 кадров/с.
      .HActive   (800),
      .HBlank    (392),
      .VActive   (480),
      .VBlank    (53)
  ) u_display (
      .pclk_i      (cam_pclk_i),
      .rst_pclk_i  (rst_pclk),
      .cam_vsync_i (cam_vsync_i),
      .cam_href_i  (cam_href_i),
      .cam_data_i  (cam_data_i),
      .stage_en_i  (stage_en),
      .kernel_sel_i(KernelSel),
      .ready_o     (pipe_ready),
      .frame_o     (frame),
      .lcd_clk_i   (lcd_clk),
      .rst_lcd_i   (rst_lcd_q[1]),
      .lcd_de_o    (lcd_de),
      .lcd_gray_o  (lcd_gray)
  );

  // --- Выводы дисплея ---------------------------------------------------------------------
  // Фронт, по которому контроллер панели ILI6122 защёлкивает данные, задаёт его вывод CLKPOL
  // (в спецификации SH500Q01Z не указан). Примеры Sipeed для этого 5" экрана (Tang Nano 9K
  // lcd_led, Mega 138K rgb_screen/800_480_screen) выводят тактовый сигнал без инверсии, а
  // данные меняют по нарастающему фронту — значит, панель защёлкивает их по спадающему, в
  // середине такта. По даташиту ILI6122 по умолчанию (CLKPOL = L) так и есть; ему нужно 8 нс
  // установки и 8 нс удержания, так что из полутакта 14,3 нс на перекос данных относительно
  // DCLK остаётся ±6,3 нс.
  //
  // Чтобы перекос не зависел от размещения, все 20 сигналов выходят из блоков ввода-вывода
  // (IOB) с одного тактового дерева: RGB и DE — с выходных регистров IOB (опция -oreg_in_iob в
  // camera_lcd.tcl), DCLK — с ODDR, который выдаёт 1 в первой половине такта и 0 во второй. Тогда
  // перекос — разница между одинаковыми IOB, доли наносекунды. У каждой ножки свой регистр:
  // R = G = B, и без syn_preserve синтез склеил бы их в один, который в IOB не поместить.
  // Регистры задерживают картинку на такт — вместе с DE, для панели это незаметно.
  // Если изображение «рябит» или сдвинуто на пиксель — поставить LcdClkInvert = 1.
  localparam bit LcdClkInvert = 1'b0;

  ODDR #(
      .TXCLK_POL(1'b0),
      .INIT     (1'b0)
  ) u_lcd_clk_oddr (
      .Q0 (lcd_clk_o),
      .Q1 (),
      .D0 (!LcdClkInvert),
      .D1 (LcdClkInvert),
      .TX (1'b0),
      .CLK(lcd_clk)
  );

  logic       lcd_de_q  /* synthesis syn_preserve = 1 */;
  logic [5:0] lcd_r_q  /* synthesis syn_preserve = 1 */;
  logic [5:0] lcd_g_q  /* synthesis syn_preserve = 1 */;
  logic [5:0] lcd_b_q  /* synthesis syn_preserve = 1 */;

  always_ff @(posedge lcd_clk) begin
    lcd_de_q <= lcd_de;
    lcd_r_q  <= lcd_gray;
    lcd_g_q  <= lcd_gray;
    lcd_b_q  <= lcd_gray;
  end

  assign lcd_de_o = lcd_de_q;
  assign lcd_r_o  = lcd_r_q;
  assign lcd_g_o  = lcd_g_q;
  assign lcd_b_o  = lcd_b_q;

  // --- Светодиоды -------------------------------------------------------------------------
  logic frame_toggle_q;

  always_ff @(posedge cam_pclk_i) begin
    if (rst_pclk) frame_toggle_q <= 1'b0;
    else if (frame) frame_toggle_q <= ~frame_toggle_q;
  end

  localparam int unsigned HalfSec = ClkFreq / 2;
  logic [$clog2(HalfSec)-1:0] blink_cnt_q;
  logic                       blink_q;

  always_ff @(posedge clk50_i) begin
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

  assign led_n_o = ~{mode_q, pipe_ready, frame_toggle_q, cam_ready, blink_q};

endmodule
