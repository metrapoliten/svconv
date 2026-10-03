`timescale 1ns / 1ps

// Кадровый буфер Width×Height (8 бит на пиксель) между двумя тактовыми доменами:
// запись — потоком valid/sof/data в домене обработки (clk_w_i), чтение — по адресу в домене
// вывода (clk_r_i), данные на rd_data_o на следующем такте clk_r_i.
//
// Буфер один (без двойной буферизации): если запись и чтение идут с разной частотой кадров,
// на экране возможен «разрыв» кадра. Адрес записи отсчитывается от sof, поэтому сбой в потоке
// исправляется со следующего кадра.
module frame_buffer #(
    parameter  int unsigned Width  = 160,
    parameter  int unsigned Height = 120,
    localparam int unsigned Pixels = Width * Height,
    localparam int unsigned AddrW  = $clog2(Pixels)
) (
    input logic       clk_w_i,
    input logic       rst_w_i,  // синхронный сброс домена записи
    input logic       valid_i,
    input logic       sof_i,
    input logic [7:0] data_i,

    input  logic             clk_r_i,
    input  logic [AddrW-1:0] rd_addr_i,
    output logic [      7:0] rd_data_o
);

  logic [7:0] mem[Pixels];

  // Запись: адрес пикселя считается от sof.
  logic [AddrW-1:0] wr_addr_q, wr_addr;

  assign wr_addr = sof_i ? '0 : wr_addr_q;

  always_ff @(posedge clk_w_i) begin
    if (rst_w_i) wr_addr_q <= '0;
    else if (valid_i) wr_addr_q <= (wr_addr == AddrW'(Pixels - 1)) ? '0 : wr_addr + 1'b1;
  end

  always_ff @(posedge clk_w_i) begin
    if (valid_i) mem[wr_addr] <= data_i;
  end

  always_ff @(posedge clk_r_i) rd_data_o <= mem[rd_addr_i];

endmodule
