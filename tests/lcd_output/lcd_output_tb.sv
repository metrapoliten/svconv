`timescale 1ns / 1ps

// Обёртка для теста: кадровый буфер (домен записи clk_w_i) + lcd_output (домен clk_pix_i).
module lcd_output_tb #(
    parameter int unsigned HActive = 40,
    parameter int unsigned HBlank = 12,
    parameter int unsigned VActive = 30,
    parameter int unsigned VBlank = 9,
    parameter int unsigned SrcWidth = 16,
    parameter int unsigned SrcHeight = 12
) (
    input logic       clk_w_i,
    input logic       rst_w_i,
    input logic       valid_i,
    input logic       sof_i,
    input logic [7:0] data_i,

    input  logic       clk_pix_i,
    input  logic       rst_pix_i,
    output logic       de_o,
    output logic [5:0] gray_o
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
      .HBlank   (HBlank),
      .VActive  (VActive),
      .VBlank   (VBlank),
      .SrcWidth (SrcWidth),
      .SrcHeight(SrcHeight)
  ) u_lcd (
      .clk_i    (clk_pix_i),
      .rst_i    (rst_pix_i),
      .fb_addr_o(fb_addr),
      .fb_data_i(fb_data),
      .de_o     (de_o),
      .gray_o   (gray_o)
  );

endmodule
