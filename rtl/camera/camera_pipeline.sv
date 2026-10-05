`timescale 1ns / 1ps

// Обработка видео с камеры в домене PCLK (не зависит от платы и способа вывода):
//
//   dvp_capture -> rgb565_to_gray -> conv_pipeline
//
// Кадр камеры Width×Height (RGB565) переводится в оттенки серого и проходит цепочку свёрток.
module camera_pipeline #(
    parameter int unsigned Width,
    parameter int unsigned Height,
    parameter int unsigned K = 5,
    parameter int unsigned NumStages = 3,
    parameter int unsigned NumKernels = 3,
    // Нетипизированный: см. conv_pipeline.sv.
    // verilog_lint: waive explicit-parameter-storage-type
    parameter KernelFile = "kernels.hex",
    // Разрядность номера ядра — определяется числом ядер.
    localparam int unsigned SelW = (NumKernels > 1) ? $clog2(NumKernels) : 1
) (
    input logic       pclk_i,
    input logic       rst_i,        // синхронный сброс в домене PCLK
    input logic       cam_vsync_i,
    input logic       cam_href_i,
    input logic [7:0] cam_data_i,

    input  logic [     NumStages-1:0] stage_en_i,
    input  logic [NumStages*SelW-1:0] kernel_sel_i,
    output logic                      ready_o,       // ядра загружены

    output logic       out_valid_o,
    output logic       out_sof_o,
    output logic [7:0] out_data_o
);

  logic cap_valid, cap_sof;
  logic [15:0] cap_data;

  dvp_capture u_capture (
      .pclk_i (pclk_i),
      .rst_i  (rst_i),
      .vsync_i(cam_vsync_i),
      .href_i (cam_href_i),
      .data_i (cam_data_i),
      .valid_o(cap_valid),
      .sof_o  (cap_sof),
      .data_o (cap_data)
  );

  logic gray_valid, gray_sof;
  logic [7:0] gray_data;

  rgb565_to_gray u_gray (
      .clk_i  (pclk_i),
      .rst_i  (rst_i),
      .valid_i(cap_valid),
      .sof_i  (cap_sof),
      .data_i (cap_data),
      .valid_o(gray_valid),
      .sof_o  (gray_sof),
      .data_o (gray_data)
  );

  conv_pipeline #(
      .Width     (Width),
      .Height    (Height),
      .K         (K),
      .NumStages (NumStages),
      .NumKernels(NumKernels),
      .KernelFile(KernelFile)
  ) u_pipeline (
      .clk_i       (pclk_i),
      .rst_i       (rst_i),
      .stage_en_i  (stage_en_i),
      .kernel_sel_i(kernel_sel_i),
      .ready_o     (ready_o),
      .valid_i     (gray_valid),
      .sof_i       (gray_sof),
      .data_i      (gray_data),
      .valid_o     (out_valid_o),
      .sof_o       (out_sof_o),
      .data_o      (out_data_o)
  );

endmodule
