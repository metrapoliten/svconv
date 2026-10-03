`timescale 1ns / 1ps

// Камера OV7670 (DVP, разъём 24P дока) -> цепочка свёрток -> RGB-LCD (разъём 40P дока)
// на Tang Primer 20K + Dock.
//
// Тактовые сигналы:
//   clk27   — генератор платы: настройка камеры, кнопка, светодиоды; он же XCLK камеры;
//   PCLK    — от камеры (при XCLK = 27 МГц и таблице регистров ov7670_init — 27 МГц):
//             захват и вся обработка;
//   lcd_clk — пиксельная частота дисплея от PLL (rPLL).
//
// Дисплей выбирается параметром LcdPreset: 0 — 4,3" 480×272 (9 МГц, увеличение ×2),
// 1 — 5" 800×480 (33 МГц, увеличение ×4). Тайминги и настройки PLL — из примеров Sipeed
// TangPrimer-20K-example (RGB_lcd). Для удобства есть обёртки camera_lcd_43_top и
// camera_lcd_50_top.
//
// Кнопка T10 переключает режим цепочки по кругу:
//   0 — размытие -> размытие -> границы (по заданию), 1 — без обработки,
//   2 — только размытие, 3 — только границы.
//
// Светодиоды дока (по шелкографии, горят при 0 на выводе):
//   LED2 — мигает раз в секунду, LED3 — камера настроена, LED4 — переключается на каждом
//   обработанном кадре (идут кадры с камеры), LED5 — ядра загружены.
module camera_lcd_top #(
    parameter int unsigned LcdPreset = 0
) (
    input logic clk27_i,
    input logic btn_n_i,  // кнопка T10, активный 0

    // Камера.
    inout  wire        cam_scl_io,
    inout  wire        cam_sda_io,
    input  logic       cam_pclk_i,
    input  logic       cam_vsync_i,
    input  logic       cam_href_i,
    input  logic [7:0] cam_data_i,
    output logic       cam_xclk_o,
    output logic       cam_rst_n_o,
    output logic       cam_pwdn_o,

    // Дисплей.
    output logic       lcd_clk_o,
    output logic       lcd_hsync_o,
    output logic       lcd_vsync_o,
    output logic       lcd_de_o,
    output logic [4:0] lcd_r_o,
    output logic [5:0] lcd_g_o,
    output logic [4:0] lcd_b_o,

    output logic [3:0] led_n_o  // LED2..LED5, активный 0
);

  localparam int unsigned ClkFreq = 27_000_000;

  // --- Наборы параметров дисплеев ---------------------------------------------------------
  localparam bit Lcd5 = (LcdPreset == 1);
  // Тайминги.
  localparam int unsigned HActive = Lcd5 ? 800 : 480;
  localparam int unsigned HFront = Lcd5 ? 40 : 2;
  localparam int unsigned HSync = Lcd5 ? 128 : 41;
  localparam int unsigned HBack = Lcd5 ? 88 : 2;
  localparam int unsigned VActive = Lcd5 ? 480 : 272;
  localparam int unsigned VFront = Lcd5 ? 1 : 2;
  localparam int unsigned VSync = Lcd5 ? 3 : 10;
  localparam int unsigned VBack = Lcd5 ? 21 : 2;
  localparam int unsigned Scale = Lcd5 ? 4 : 2;
  // rPLL: Fout = 27 МГц * (FBDIV_SEL + 1) / (IDIV_SEL + 1); VCO = Fout * ODIV_SEL.
  // 4,3": 27 * 1 / 3 = 9 МГц (VCO 576 МГц); 5": 27 * 11 / 9 = 33 МГц (VCO 528 МГц).
  localparam int unsigned PllIdiv = Lcd5 ? 8 : 2;
  localparam int unsigned PllFbdiv = Lcd5 ? 10 : 0;
  localparam int unsigned PllOdiv = Lcd5 ? 16 : 64;

  // --- Сброс после включения (домен clk27) ------------------------------------------------
  logic [3:0] por_cnt_q = '0;
  logic       rst;

  always_ff @(posedge clk27_i) begin
    if (por_cnt_q != '1) por_cnt_q <= por_cnt_q + 1'b1;
  end
  assign rst = (por_cnt_q != '1);

  // --- Пиксельная частота дисплея ---------------------------------------------------------
  logic lcd_clk, pll_lock;

  rPLL #(
      .FCLKIN("27"),
      .DYN_IDIV_SEL("false"),
      .IDIV_SEL(PllIdiv),
      .DYN_FBDIV_SEL("false"),
      .FBDIV_SEL(PllFbdiv),
      .DYN_ODIV_SEL("false"),
      .ODIV_SEL(PllOdiv),
      .PSDA_SEL("0000"),
      .DYN_DA_EN("true"),
      .DUTYDA_SEL("1000"),
      .CLKOUT_FT_DIR(1'b1),
      .CLKOUTP_FT_DIR(1'b1),
      .CLKOUT_DLY_STEP(0),
      .CLKOUTP_DLY_STEP(0),
      .CLKFB_SEL("internal"),
      .CLKOUT_BYPASS("false"),
      .CLKOUTP_BYPASS("false"),
      .CLKOUTD_BYPASS("false"),
      .DYN_SDIV_SEL(2),
      .CLKOUTD_SRC("CLKOUT"),
      .CLKOUTD3_SRC("CLKOUT"),
      .DEVICE("GW2A-18C")
  ) u_lcd_pll (
      .CLKOUT  (lcd_clk),
      .LOCK    (pll_lock),
      .CLKOUTP (),
      .CLKOUTD (),
      .CLKOUTD3(),
      .RESET   (1'b0),
      .RESET_P (1'b0),
      .CLKIN   (clk27_i),
      .CLKFB   (1'b0),
      .FBDSEL  (6'b0),
      .IDSEL   (6'b0),
      .ODSEL   (6'b0),
      .PSDA    (4'b0),
      .DUTYDA  (4'b0),
      .FDLY    (4'b0)
  );

  assign lcd_clk_o = lcd_clk;

  // Сброс домена LCD: держим, пока PLL не захватил частоту; снимаем синхронно через два
  // триггера. От домена clk27 сюда ничего не идёт, так что междоменного перехода нет.
  logic [1:0] rst_lcd_q;

  always_ff @(posedge lcd_clk or negedge pll_lock) begin
    if (!pll_lock) rst_lcd_q <= 2'b11;
    else rst_lcd_q <= {rst_lcd_q[0], 1'b0};
  end

  // --- Камера: XCLK и настройка ---------------------------------------------------------
  assign cam_xclk_o = clk27_i;

  logic sioc_oe, siod_oe, cam_ready;

  ov7670_init #(
      .ClkFreq (ClkFreq),
      .SccbFreq(100_000)
  ) u_cam_init (
      .clk_i      (clk27_i),
      .rst_i      (rst),
      .cam_rst_n_o(cam_rst_n_o),
      .cam_pwdn_o (cam_pwdn_o),
      .sioc_oe_o  (sioc_oe),
      .siod_oe_o  (siod_oe),
      .done_o     (cam_ready)
  );

  // Открытый сток: ПЛИС только прижимает линии к нулю.
  assign cam_scl_io = sioc_oe ? 1'b0 : 1'bz;
  assign cam_sda_io = siod_oe ? 1'b0 : 1'bz;

  // --- Режим цепочки: кнопка в домене clk27 ----------------------------------------------
  logic btn_press;
  logic [1:0] mode_q;

  button #(
      .StableClks(ClkFreq / 100),
      .ActiveLow (1'b1)
  ) u_button (
      .clk_i    (clk27_i),
      .rst_i    (rst),
      .btn_i    (btn_n_i),
      .pressed_o(),
      .press_o  (btn_press)
  );

  always_ff @(posedge clk27_i) begin
    if (rst) mode_q <= '0;
    else if (btn_press) mode_q <= mode_q + 1'b1;
  end

  // Номера ядер — порядок KERNEL_ROM_ORDER в модели: 0 identity, 1 gauss5, 2 log5.
  localparam int unsigned SelW = 2;
  logic [       2:0] stage_en;
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

  camera_display #(
      .Width     (160),
      .Height    (120),
      .Factor    (4),
      .K         (5),
      .NumStages (3),
      .NumKernels(3),
      .KernelFile("kernels.hex"),
      .SelW      (SelW),
      .HActive   (HActive),
      .HFront    (HFront),
      .HSync     (HSync),
      .HBack     (HBack),
      .VActive   (VActive),
      .VFront    (VFront),
      .VSync     (VSync),
      .VBack     (VBack),
      .HSyncPol  (1'b0),
      .VSyncPol  (1'b0),
      .Scale     (Scale)
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
      .lcd_hsync_o (lcd_hsync_o),
      .lcd_vsync_o (lcd_vsync_o),
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

  assign led_n_o = ~{pipe_ready, frame_toggle_q, cam_ready, blink_q};

endmodule

// Обёртки с выбранным дисплеем.
module camera_lcd_43_top (
    input  logic       clk27_i,
    input  logic       btn_n_i,
    inout  wire        cam_scl_io,
    inout  wire        cam_sda_io,
    input  logic       cam_pclk_i,
    input  logic       cam_vsync_i,
    input  logic       cam_href_i,
    input  logic [7:0] cam_data_i,
    output logic       cam_xclk_o,
    output logic       cam_rst_n_o,
    output logic       cam_pwdn_o,
    output logic       lcd_clk_o,
    output logic       lcd_hsync_o,
    output logic       lcd_vsync_o,
    output logic       lcd_de_o,
    output logic [4:0] lcd_r_o,
    output logic [5:0] lcd_g_o,
    output logic [4:0] lcd_b_o,
    output logic [3:0] led_n_o
);
  camera_lcd_top #(.LcdPreset(0)) u_top (.*);
endmodule

module camera_lcd_50_top (
    input  logic       clk27_i,
    input  logic       btn_n_i,
    inout  wire        cam_scl_io,
    inout  wire        cam_sda_io,
    input  logic       cam_pclk_i,
    input  logic       cam_vsync_i,
    input  logic       cam_href_i,
    input  logic [7:0] cam_data_i,
    output logic       cam_xclk_o,
    output logic       cam_rst_n_o,
    output logic       cam_pwdn_o,
    output logic       lcd_clk_o,
    output logic       lcd_hsync_o,
    output logic       lcd_vsync_o,
    output logic       lcd_de_o,
    output logic [4:0] lcd_r_o,
    output logic [5:0] lcd_g_o,
    output logic [4:0] lcd_b_o,
    output logic [3:0] led_n_o
);
  camera_lcd_top #(.LcdPreset(1)) u_top (.*);
endmodule
