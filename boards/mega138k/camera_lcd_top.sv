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
// и выводится без увеличения по центру экрана 800×480. Тайминги дисплея (только DE), частота
// 35 МГц и неинвертированный тактовый сигнал дисплея — как в примере Sipeed
// TangMega-138KPro-example/rgb_screen/800_480_screen; тайминги укладываются в допуски
// контроллера панели ILI6122 (см. ниже). Цвет — RGB666 (6 старших бит каждого
// канала выведены на разъём дока), R = G = B = оттенок серого.
//
// Камера OV7670 — модуль 2×9 на проводах «мама–папа» к гнёздам PMOD дока: управление —
// PMOD1 (J24), данные D0..D7 — PMOD2 (J26), питание 3,3 В и земля — контакты 1 и 3 любого из
// них (таблица — в camera_lcd.cst). Назначение сигналов по гнёздам — как в закомментированном
// варианте примера Sipeed dvp_rgb; RESET и PWDN — на два оставшихся контакта PMOD1.
//
// Кнопка S1 переключает режим цепочки по кругу:
//   0 — размытие -> размытие -> границы (по заданию), 1 — без обработки,
//   2 — только размытие, 3 — только границы.
//
// Светодиоды дока (горят при 0): LED0 — мигает раз в секунду, LED1 — камера настроена,
// LED2 — переключается на каждом обработанном кадре, LED3 — ядра загружены,
// LED4, LED5 — номер режима.
module camera_lcd_top (
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

  PLL #(
      .FCLKIN("50"),
      .IDIV_SEL(1),
      .FBDIV_SEL(1),
      .MDIV_SEL(21),
      .MDIV_FRAC_SEL(0),
      .ODIV0_SEL(30),
      .ODIV0_FRAC_SEL(0),
      .ODIV1_SEL(42),
      .ODIV2_SEL(8),
      .ODIV3_SEL(8),
      .ODIV4_SEL(8),
      .ODIV5_SEL(8),
      .ODIV6_SEL(8),
      .CLKFB_SEL("INTERNAL"),
      .CLKOUT0_EN("TRUE"),
      .CLKOUT1_EN("TRUE"),
      .CLKOUT2_EN("FALSE"),
      .CLKOUT3_EN("FALSE"),
      .CLKOUT4_EN("FALSE"),
      .CLKOUT5_EN("FALSE"),
      .CLKOUT6_EN("FALSE"),
      .DYN_IDIV_SEL("FALSE"),
      .DYN_FBDIV_SEL("FALSE"),
      .DYN_MDIV_SEL("FALSE"),
      .DYN_ODIV0_SEL("FALSE"),
      .DYN_ODIV1_SEL("FALSE"),
      .DYN_ODIV2_SEL("FALSE"),
      .DYN_ODIV3_SEL("FALSE"),
      .DYN_ODIV4_SEL("FALSE"),
      .DYN_ODIV5_SEL("FALSE"),
      .DYN_ODIV6_SEL("FALSE"),
      .DYN_DT0_SEL("FALSE"),
      .DYN_DT1_SEL("FALSE"),
      .DYN_DT2_SEL("FALSE"),
      .DYN_DT3_SEL("FALSE"),
      .DYN_ICP_SEL("FALSE"),
      .DYN_LPF_SEL("FALSE"),
      .RESET_I_EN("FALSE"),
      .RESET_O_EN("FALSE"),
      .SSC_EN("FALSE")
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

  // Фронт, по которому контроллер панели ILI6122 защёлкивает данные, задаёт его вывод CLKPOL
  // (в спецификации SH500Q01Z не указан). Примеры Sipeed для этого 5" экрана (Tang Nano 9K
  // lcd_led, Mega 138K rgb_screen/800_480_screen) выводят тактовый сигнал без инверсии, а
  // данные меняют по нарастающему фронту — значит, панель защёлкивает их по спадающему, в
  // середине такта (запас до 14 нс при требуемых ILI6122 8 нс установки и 8 нс удержания).
  // Если изображение «рябит» или сдвинуто на пиксель — поставить LcdClkInvert = 1.
  localparam bit LcdClkInvert = 1'b0;
  assign lcd_clk_o = LcdClkInvert ? ~lcd_clk : lcd_clk;

  // Сброс домена LCD — пока PLL не захватил частоту; снимается синхронно.
  logic [1:0] rst_lcd_q;

  always_ff @(posedge lcd_clk or negedge pll_lock) begin
    if (!pll_lock) rst_lcd_q <= 2'b11;
    else rst_lcd_q <= {rst_lcd_q[0], 1'b0};
  end

  // --- Камера: XCLK и настройка по SCCB ---------------------------------------------------
  assign cam_xclk_o = cam_clk;

  logic sioc_oe, siod_oe, cam_ready;

  ov7670_init #(
      .ClkFreq (ClkFreq),
      .SccbFreq(100_000)
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
      .StableClks(ClkFreq / 100),
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

  // Номера ядер — порядок KERNEL_ROM_ORDER в модели: 0 identity, 1 gauss5, 2 log5.
  localparam int unsigned SelW = 2;
  logic [2:0] stage_en;
  logic [3*SelW-1:0] kernel_sel;

  always_comb begin
    unique case (mode_q)
      2'd0:
      {stage_en, kernel_sel} = {
        3'b111, 2'd2, 2'd1, 2'd1
      };  // размытие, размытие, границы
      2'd1: {stage_en, kernel_sel} = {3'b000, 2'd0, 2'd0, 2'd0};  // без обработки
      2'd2: {stage_en, kernel_sel} = {3'b001, 2'd0, 2'd0, 2'd1};  // только размытие
      default: {stage_en, kernel_sel} = {3'b100, 2'd2, 2'd0, 2'd0};  // только границы
    endcase
  end

  // Домен PCLK: синхронизация сброса и режима (режим меняется редко; кадр, во время
  // которого он сменился, может быть смешанным).
  logic [1:0] rst_pclk_q;
  logic [8:0] cfg_meta_q, cfg_q;

  always_ff @(posedge cam_pclk_i) begin
    rst_pclk_q <= {rst_pclk_q[0], rst};
    cfg_meta_q <= {stage_en, kernel_sel};
    cfg_q      <= cfg_meta_q;
  end

  // --- Обработка и вывод ------------------------------------------------------------------
  logic pipe_ready, frame;
  logic
      lcd_hsync,
      lcd_vsync;  // дисплей работает в режиме DE, синхроимпульсы не выводятся

  camera_display #(
      .Width     (640),
      .Height    (480),
      .Factor    (1),
      .K         (5),
      .NumStages (3),
      .NumKernels(3),
      .KernelFile("kernels.hex"),
      .SelW      (SelW),
      // Тайминги — как в примере Sipeed: строка 800 + 210 + 182, кадр 480 + 45 + 8; в режиме
      // DE важны только видимая область и полный период, синхроимпульс — 1 такт/строка.
      // Допуски ILI6122 (800×480): строка 862..1200 тактов (здесь 1192), кадр 510..650 строк
      // (здесь 533), частота до 50 МГц (здесь 35) — около 55 кадров/с.
      .HActive   (800),
      .HFront    (210),
      .HSync     (1),
      .HBack     (181),
      .VActive   (480),
      .VFront    (45),
      .VSync     (1),
      .VBack     (7),
      .HSyncPol  (1'b0),
      .VSyncPol  (1'b0),
      .Scale     (1),
      .RBits     (6),
      .GBits     (6),
      .BBits     (6)
  ) u_display (
      .pclk_i      (cam_pclk_i),
      .rst_pclk_i  (rst_pclk_q[1]),
      .cam_vsync_i (cam_vsync_i),
      .cam_href_i  (cam_href_i),
      .cam_data_i  (cam_data_i),
      .stage_en_i  (cfg_q[8:6]),
      .kernel_sel_i(cfg_q[5:0]),
      .ready_o     (pipe_ready),
      .frame_o     (frame),
      .lcd_clk_i   (lcd_clk),
      .rst_lcd_i   (rst_lcd_q[1]),
      .lcd_hsync_o (lcd_hsync),
      .lcd_vsync_o (lcd_vsync),
      .lcd_de_o    (lcd_de_o),
      .lcd_r_o     (lcd_r_o),
      .lcd_g_o     (lcd_g_o),
      .lcd_b_o     (lcd_b_o)
  );

  // --- Светодиоды -------------------------------------------------------------------------
  logic frame_toggle_q;

  always_ff @(posedge cam_pclk_i) begin
    if (rst_pclk_q[1]) frame_toggle_q <= 1'b0;
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
