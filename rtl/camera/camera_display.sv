`timescale 1ns / 1ps

// Обработка видео с камеры и вывод на RGB-LCD (не зависит от платы):
//
//   домен PCLK камеры:  dvp_capture -> frame_decimator -> rgb565_to_gray -> conv_pipeline
//                       -> запись в frame_buffer
//   домен пикселей LCD: lcd_output читает frame_buffer
//
// Кадр камеры (RGB565) прореживается в Factor раз до Width×Height, переводится в оттенки
// серого и проходит цепочку свёрток. Конфигурация цепочки (stage_en_i, kernel_sel_i) задаётся
// в домене PCLK; её следует менять редко (см. conv_pipeline).
module camera_display #(
    // Обработка.
    parameter int unsigned Width = 160,
    parameter int unsigned Height = 120,
    parameter int unsigned Factor = 4,
    parameter int unsigned K = 5,
    parameter int unsigned NumStages = 3,
    parameter int unsigned NumKernels = 3,
    // Нетипизированный: см. conv_pipeline.sv.
    // verilog_lint: waive explicit-parameter-storage-type
    parameter KernelFile = "kernels.hex",
    parameter int unsigned SelW = (NumKernels > 1) ? $clog2(NumKernels) : 1,
    // Дисплей.
    parameter int unsigned HActive = 480,
    parameter int unsigned HFront = 2,
    parameter int unsigned HSync = 41,
    parameter int unsigned HBack = 2,
    parameter int unsigned VActive = 272,
    parameter int unsigned VFront = 2,
    parameter int unsigned VSync = 10,
    parameter int unsigned VBack = 2,
    parameter bit HSyncPol = 1'b0,
    parameter bit VSyncPol = 1'b0,
    parameter int unsigned Scale = 2
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
    input  logic       lcd_clk_i,
    input  logic       rst_lcd_i,    // синхронный сброс в домене LCD
    output logic       lcd_hsync_o,
    output logic       lcd_vsync_o,
    output logic       lcd_de_o,
    output logic [4:0] lcd_r_o,
    output logic [5:0] lcd_g_o,
    output logic [4:0] lcd_b_o
);

  localparam int unsigned AddrW = $clog2(Width * Height);

  // --- Домен PCLK -------------------------------------------------------------------------
  logic cap_valid, cap_sof, cap_sol;
  logic [15:0] cap_data;

  dvp_capture u_capture (
      .pclk_i (pclk_i),
      .rst_i  (rst_pclk_i),
      .vsync_i(cam_vsync_i),
      .href_i (cam_href_i),
      .data_i (cam_data_i),
      .valid_o(cap_valid),
      .sof_o  (cap_sof),
      .sol_o  (cap_sol),
      .data_o (cap_data)
  );

  logic dec_valid, dec_sof;
  logic [15:0] dec_data;

  frame_decimator #(
      .DataW    (16),
      .Factor   (Factor),
      .OutWidth (Width),
      .OutHeight(Height)
  ) u_decimator (
      .clk_i  (pclk_i),
      .rst_i  (rst_pclk_i),
      .valid_i(cap_valid),
      .sof_i  (cap_sof),
      .sol_i  (cap_sol),
      .data_i (cap_data),
      .valid_o(dec_valid),
      .sof_o  (dec_sof),
      .data_o (dec_data)
  );

  logic gray_valid, gray_sof;
  logic [7:0] gray_data;

  rgb565_to_gray u_gray (
      .clk_i  (pclk_i),
      .rst_i  (rst_pclk_i),
      .valid_i(dec_valid),
      .sof_i  (dec_sof),
      .data_i (dec_data),
      .valid_o(gray_valid),
      .sof_o  (gray_sof),
      .data_o (gray_data)
  );

  logic pipe_valid, pipe_sof;
  logic [7:0] pipe_data;

  conv_pipeline #(
      .Width     (Width),
      .Height    (Height),
      .K         (K),
      .NumStages (NumStages),
      .NumKernels(NumKernels),
      .KernelFile(KernelFile),
      .SelW      (SelW)
  ) u_pipeline (
      .clk_i       (pclk_i),
      .rst_i       (rst_pclk_i),
      .stage_en_i  (stage_en_i),
      .kernel_sel_i(kernel_sel_i),
      .ready_o     (ready_o),
      .valid_i     (gray_valid),
      .sof_i       (gray_sof),
      .data_i      (gray_data),
      .valid_o     (pipe_valid),
      .sof_o       (pipe_sof),
      .data_o      (pipe_data)
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
      .HFront   (HFront),
      .HSync    (HSync),
      .HBack    (HBack),
      .VActive  (VActive),
      .VFront   (VFront),
      .VSync    (VSync),
      .VBack    (VBack),
      .HSyncPol (HSyncPol),
      .VSyncPol (VSyncPol),
      .SrcWidth (Width),
      .SrcHeight(Height),
      .Scale    (Scale)
  ) u_lcd (
      .clk_i    (lcd_clk_i),
      .rst_i    (rst_lcd_i),
      .fb_addr_o(fb_addr),
      .fb_data_i(fb_data),
      .hsync_o  (lcd_hsync_o),
      .vsync_o  (lcd_vsync_o),
      .de_o     (lcd_de_o),
      .r_o      (lcd_r_o),
      .g_o      (lcd_g_o),
      .b_o      (lcd_b_o)
  );

endmodule
