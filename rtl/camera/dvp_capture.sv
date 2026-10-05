`timescale 1ns / 1ps

// Захват кадров с камеры по параллельному интерфейсу DVP в формате RGB565.
//
// Работает в домене PCLK камеры. Данные D[7:0] выбираются по фронту PCLK; пока HREF = 1,
// идут пиксели строки, каждый двумя байтами: {R[4:0], G[5:3]}, затем {G[2:0], B[4:0]}.
// Импульс VSYNC = 1 отмечает начало кадра (так OV7670 работает по умолчанию).
// PCLK должен идти непрерывно, в том числе при HREF = 0 и VSYNC = 1 (у OV7670 — COM10[5] = 0):
// иначе модуль не увидит ни VSYNC, ни паузы между строками.
//
// Выход — поток пикселей RGB565: valid_o, sof_o у первого пикселя кадра, sol_o у первого
// пикселя каждой строки. Задержка — 2 такта PCLK (входные регистры и сборка пикселя).
module dvp_capture (
    input logic pclk_i,
    input logic rst_i,  // синхронный сброс в домене PCLK, активный уровень 1

    input logic       vsync_i,
    input logic       href_i,
    input logic [7:0] data_i,

    output logic        valid_o,
    output logic        sof_o,
    output logic        sol_o,
    output logic [15:0] data_o
);

  // Входные регистры: сигналы камеры выбираются в одном такте.
  logic vsync_q, href_q;
  logic [7:0] data_q;

  always_ff @(posedge pclk_i) begin
    vsync_q <= vsync_i;
    href_q  <= href_i;
    data_q  <= data_i;
  end

  logic       second_byte_q;  // ждём второй байт пикселя
  logic       frame_start_q;  // следующий пиксель — первый в кадре
  logic       line_start_q;  // следующий пиксель — первый в строке
  logic [7:0] high_byte_q;

  always_ff @(posedge pclk_i) begin
    if (rst_i) begin
      second_byte_q <= 1'b0;
      frame_start_q <= 1'b0;
      line_start_q  <= 1'b1;
      valid_o       <= 1'b0;
      sof_o         <= 1'b0;
      sol_o         <= 1'b0;
    end else begin
      valid_o <= 1'b0;
      if (vsync_q) begin
        frame_start_q <= 1'b1;
        line_start_q  <= 1'b1;
        second_byte_q <= 1'b0;
      end else if (href_q) begin
        if (!second_byte_q) begin
          high_byte_q   <= data_q;
          second_byte_q <= 1'b1;
        end else begin
          valid_o       <= 1'b1;
          sof_o         <= frame_start_q;
          sol_o         <= line_start_q;
          data_o        <= {high_byte_q, data_q};
          frame_start_q <= 1'b0;
          line_start_q  <= 1'b0;
          second_byte_q <= 1'b0;
        end
      end else begin
        line_start_q  <= 1'b1;
        second_byte_q <= 1'b0;
      end
    end
  end

endmodule
