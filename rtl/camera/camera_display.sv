`timescale 1ns / 1ps

// Обработка видео с камеры и вывод на RGB-LCD (не зависит от платы):
//
//   домен PCLK камеры:  camera_pipeline (захват, серый, свёртки)
//                       -> запись в frame_buffer
//   домен пикселей LCD: lcd_output читает frame_buffer
//
// Конфигурация цепочки (stage_en_i, kernel_sel_i) задаётся в домене PCLK; её следует менять
// редко (см. conv_pipeline). На дисплей выходит уровень серого RGB666 (см. lcd_frame_reader).
module camera_display #(
    // Обработка.
    parameter int unsigned Width,
    parameter int unsigned Height,
    parameter int unsigned K = 5,
    parameter int unsigned NumStages = 3,
    parameter int unsigned NumKernels = 3,
    // Нетипизированный: см. conv_pipeline.sv.
    // verilog_lint: waive explicit-parameter-storage-type
    parameter KernelFile = "kernels.hex",
    // Дисплей (режим DE, см. video_timing).
    parameter int unsigned HActive,
    parameter int unsigned HBlank,
    parameter int unsigned VActive,
    parameter int unsigned VBlank,
    // Разрядность номера ядра — определяется числом ядер.
    localparam int unsigned SelW = (NumKernels > 1) ? $clog2(NumKernels) : 1
) (
    // Камера.
    input logic       pclk_i,
    input logic       rst_pclk_i,   // синхронный сброс в домене PCLK
    input logic       cam_vsync_i,
    input logic       cam_href_i,
    input logic [7:0] cam_data_i,

    input logic [NumStages-1:0] stage_en_i,
    input logic [NumStages*SelW-1:0] kernel_sel_i,
    output logic ready_o,  // ядра загружены (домен PCLK)
    output logic frame_o,  // импульс на каждый обработанный кадр

    // Дисплей.
    input logic lcd_clk_i,
    input logic rst_lcd_i,  // синхронный сброс в домене LCD
    output logic lcd_de_o,
    output logic [5:0] lcd_gray_o  // уровень серого, RGB666: один и тот же на R, G и B
);

  localparam int unsigned AddrW = $clog2(Width * Height);

  // --- Домен PCLK -------------------------------------------------------------------------
  logic pipe_valid, pipe_sof;
  logic [7:0] pipe_data;

  camera_pipeline #(
      .Width     (Width),
      .Height    (Height),
      .K         (K),
      .NumStages (NumStages),
      .NumKernels(NumKernels),
      .KernelFile(KernelFile)
  ) u_camera (
      .pclk_i      (pclk_i),
      .rst_i       (rst_pclk_i),
      .cam_vsync_i (cam_vsync_i),
      .cam_href_i  (cam_href_i),
      .cam_data_i  (cam_data_i),
      .stage_en_i  (stage_en_i),
      .kernel_sel_i(kernel_sel_i),
      .ready_o     (ready_o),
      .out_valid_o (pipe_valid),
      .out_sof_o   (pipe_sof),
      .out_data_o  (pipe_data)
  );

  assign frame_o = pipe_valid && pipe_sof;

  // --- Кадровый буфер между доменами ---------------------------------------------------
  logic [AddrW-1:0] fb_addr;
  logic [      7:0] fb_data;

  frame_buffer #(
      .Width (Width),
      .Height(Height)
  ) u_frame_buffer (
      .clk_w_i  (pclk_i),
      .rst_w_i  (rst_pclk_i),
      .valid_i  (pipe_valid),
      .sof_i    (pipe_sof),
      .data_i   (pipe_data),
      .clk_r_i  (lcd_clk_i),
      .rd_addr_i(fb_addr),
      .rd_data_o(fb_data)
  );

  // --- Домен LCD --------------------------------------------------------------------------
  lcd_output #(
      .HActive  (HActive),
      .HBlank   (HBlank),
      .VActive  (VActive),
      .VBlank   (VBlank),
      .SrcWidth (Width),
      .SrcHeight(Height)
  ) u_lcd (
      .clk_i    (lcd_clk_i),
      .rst_i    (rst_lcd_i),
      .fb_addr_o(fb_addr),
      .fb_data_i(fb_data),
      .de_o     (lcd_de_o),
      .gray_o   (lcd_gray_o)
  );

endmodule
