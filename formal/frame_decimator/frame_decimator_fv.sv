`timescale 1ns / 1ps

// Формальная проверка frame_decimator: для любых данных и любых кадров (sof — в начале каждого
// кадра, sol — в начале каждой строки) на выходе ровно те пиксели, которые должны остаться:
// левый верхний пиксель каждого квадрата Factor×Factor в области OutWidth×OutHeight,
// с теми же данными, на такт позже; sof_o — ровно у пикселя (0, 0).
//
// Пиксели подаются каждый такт: состояние модуля меняется только по valid_i, поэтому такты
// без пикселя на результат не влияют (работа с паузами проверяется тестами cocotb). Кадр
// входа — InWidth×InHeight, больше, чем Factor*OutWidth × Factor*OutHeight, чтобы проверялось
// и отбрасывание лишнего. Он настолько велик (> Factor * 2^XW, где XW — разрядность счётчика x
// внутри модуля), что без остановки счётчиков x и y на OutWidth/OutHeight они бы переполнились
// и выдали лишние пиксели — так проверяется и эта защита.
module frame_decimator_fv (
    input logic clk_i,
    input logic rst_i,
    input logic [3:0] data_i,
    input logic       restart_i  // начать новый кадр раньше времени (оборванный кадр)
);

  localparam int unsigned Factor  = 2, OutWidth = 2, OutHeight = 2;
  localparam int unsigned InWidth = 9, InHeight = 9;

  logic init_q = 1'b1;
  always_ff @(posedge clk_i) init_q <= 1'b0;
  always_comb assume (rst_i == init_q);

  // Позиция текущего входного пикселя; restart_i начинает кадр заново с текущего пикселя.
  logic [3:0] ix_q = '0, iy_q = '0, ix, iy;
  logic sof, sol;

  always_comb begin
    ix  = restart_i ? '0 : ix_q;
    iy  = restart_i ? '0 : iy_q;
    sof = (ix == 0) && (iy == 0);
    sol = (ix == 0);
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      ix_q <= '0;
      iy_q <= '0;
    end else if (ix == 4'(InWidth - 1)) begin
      ix_q <= '0;
      iy_q <= (iy == 4'(InHeight - 1)) ? '0 : iy + 1'b1;
    end else begin
      ix_q <= ix + 1'b1;
      iy_q <= iy;
    end
  end

  logic valid_o, sof_o;
  logic [3:0] data_o;

  frame_decimator #(
      .DataW    (4),
      .Factor   (Factor),
      .OutWidth (OutWidth),
      .OutHeight(OutHeight)
  ) dut (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .valid_i(!rst_i),
      .sof_i  (sof),
      .sol_i  (sol),
      .data_i (data_i),
      .valid_o(valid_o),
      .sof_o  (sof_o),
      .data_o (data_o)
  );

  // Ожидаемый выход — входной пиксель, если он должен остаться, на такт позже.
  logic keep;
  logic exp_valid_q = 1'b0, exp_sof_q = 1'b0;
  logic [3:0] exp_data_q;

  assign keep = (ix % Factor == 0) && (iy % Factor == 0) &&
                (ix / Factor < OutWidth) && (iy / Factor < OutHeight);

  always_ff @(posedge clk_i) begin
    exp_valid_q <= !rst_i && keep;
    exp_sof_q   <= !rst_i && sof;
    exp_data_q  <= data_i;
  end

  always_comb begin
    if (!init_q) begin
      assert (valid_o == exp_valid_q);
      assert (sof_o == exp_sof_q);
      if (valid_o) assert (data_o == exp_data_q);
    end
  end

endmodule
