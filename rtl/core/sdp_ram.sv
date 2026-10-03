`timescale 1ns / 1ps

// Память с отдельными портами записи и чтения (simple dual-port), один тактовый сигнал.
// Чтение синхронное: данные по адресу raddr_i появляются на rdata_o на следующем такте.
// Синтезатор Gowin отображает такую память в блок BSRAM в режиме SDP (или в распределённую
// память SSRAM, если она маленькая). Одновременные запись и чтение одной ячейки не используются.
module sdp_ram #(
    parameter int unsigned Depth = 160,
    parameter int unsigned DataW = 8
) (
    input  logic                     clk_i,
    input  logic                     we_i,
    input  logic [$clog2(Depth)-1:0] waddr_i,
    input  logic [        DataW-1:0] wdata_i,
    input  logic [$clog2(Depth)-1:0] raddr_i,
    output logic [        DataW-1:0] rdata_o
);

  logic [DataW-1:0] mem[Depth];

  always_ff @(posedge clk_i) begin
    if (we_i) mem[waddr_i] <= wdata_i;
    rdata_o <= mem[raddr_i];
  end

endmodule
