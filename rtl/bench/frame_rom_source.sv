`timescale 1ns / 1ps

// Источник кадров из ПЗУ: бесконечно выдаёт изображение Width×Height (по строкам, 8 бит на
// пиксель) по пикселю в такт, sof_o — у первого пикселя каждого кадра. Содержимое ПЗУ —
// из ImageFile ($readmemh, генерирует model/gen_hex.py). Используется для проверки
// конвейера на плате без камеры: на нём он работает на предельной скорости 1 пиксель/такт.
module frame_rom_source #(
    parameter int unsigned Width = 160,
    parameter int unsigned Height = 120,
    // Нетипизированный: см. conv_pipeline.sv.
    // verilog_lint: waive explicit-parameter-storage-type
    parameter ImageFile = "image.hex"
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1

    output logic       valid_o,
    output logic       sof_o,
    output logic [7:0] data_o
);

  localparam int unsigned Pixels = Width * Height;
  localparam int unsigned AddrW  = $clog2(Pixels);

  logic [7:0] rom[Pixels];

  initial $readmemh(ImageFile, rom);

  logic [AddrW-1:0] addr_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) addr_q <= '0;
    else addr_q <= (addr_q == AddrW'(Pixels - 1)) ? '0 : addr_q + 1'b1;
  end

  // Чтение синхронное: данные и признаки выходят на такт позже адреса.
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      valid_o <= 1'b0;
      sof_o   <= 1'b0;
    end else begin
      valid_o <= 1'b1;
      sof_o   <= (addr_q == '0);
    end
    data_o <= rom[addr_q];
  end

endmodule
