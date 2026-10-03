`timescale 1ns / 1ps

// Обёртка для теста: кадровый буфер (домен записи clk_w_i) + lcd_output (домен clk_pix_i).
module lcd_output_tb #(
    parameter int unsigned HActive = 40,
    parameter int unsigned HFront = 3,
    parameter int unsigned HSync = 4,
    parameter int unsigned HBack = 5,
    parameter int unsigned VActive = 30,
    parameter int unsigned VFront = 2,
    parameter int unsigned VSync = 3,
    parameter int unsigned VBack = 4,
    parameter int unsigned SrcWidth = 16,
    parameter int unsigned SrcHeight = 12,
    parameter int unsigned Scale = 2
) (
    input logic       clk_w_i,
    input logic       rst_w_i,
    input logic       valid_i,
    input logic       sof_i,
    input logic [7:0] data_i,

    input  logic       clk_pix_i,
    input  logic       rst_pix_i,
    output logic       hsync_o,
    output logic       vsync_o,
    output logic       de_o,
    output logic [4:0] r_o,
    output logic [5:0] g_o,
    output logic [4:0] b_o
);

  localparam int unsigned AddrW = $clog2(SrcWidth * SrcHeight);

  logic [AddrW-1:0] fb_addr;
  logic [      7:0] fb_data;

  frame_buffer #(
      .Width (SrcWidth),
      .Height(SrcHeight)
  ) u_fb (
      .clk_w_i  (clk_w_i),
      .rst_w_i  (rst_w_i),
      .valid_i  (valid_i),
      .sof_i    (sof_i),
      .data_i   (data_i),
      .clk_r_i  (clk_pix_i),
      .rd_addr_i(fb_addr),
      .rd_data_o(fb_data)
  );

  lcd_output #(
      .HActive  (HActive),
      .HFront   (HFront),
      .HSync    (HSync),
      .HBack    (HBack),
      .VActive  (VActive),
      .VFront   (VFront),
      .VSync    (VSync),
      .VBack    (VBack),
      .HSyncPol (1'b0),
      .VSyncPol (1'b0),
      .SrcWidth (SrcWidth),
      .SrcHeight(SrcHeight),
      .Scale    (Scale)
  ) u_lcd (
      .clk_i    (clk_pix_i),
      .rst_i    (rst_pix_i),
      .fb_addr_o(fb_addr),
      .fb_data_i(fb_data),
      .hsync_o  (hsync_o),
      .vsync_o  (vsync_o),
      .de_o     (de_o),
      .r_o      (r_o),
      .g_o      (g_o),
      .b_o      (b_o)
  );

endmodule
