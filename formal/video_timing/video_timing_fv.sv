`timescale 1ns / 1ps

// Формальная проверка video_timing: выходы, измеренные снаружи, соответствуют параметрам.
// Параметры уменьшены, чтобы доказательство было быстрым.
module video_timing_fv (
    input logic clk_i,
    input logic rst_i
);

  localparam int unsigned HActive  = 3, HBlank = 2;
  localparam int unsigned VActive  = 2, VBlank = 2;
  localparam int unsigned HTotal   = HActive + HBlank;
  localparam int unsigned VTotal   = VActive + VBlank;
  // Между началами последней строки кадра и первой строки следующего — гашение кадра.
  localparam int unsigned FrameGap = (VBlank + 1) * HTotal;

  logic de;
  logic [$clog2(HTotal)-1:0] x;
  logic [$clog2(VTotal)-1:0] y;

  video_timing #(
      .HActive(HActive),
      .HBlank (HBlank),
      .VActive(VActive),
      .VBlank (VBlank)
  ) dut (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .de_o (de),
      .x_o  (x),
      .y_o  (y)
  );

  // Сброс в первом такте, дальше — без сброса. Координаты на выходе — регистры без сброса:
  // согласованы с DE со второго такта после него.
  logic init_q = 1'b1, settled_q = 1'b0;
  always_ff @(posedge clk_i) begin
    init_q <= 1'b0;
    settled_q <= !init_q;
  end
  always_comb assume (rst_i == init_q);

  // Наблюдатель: начала строк (фронт DE), длина видимой части, строки в кадре.
  logic de_q = 1'b0;
  logic seen_q = 1'b0;  // было хотя бы одно начало строки
  logic frame_seen_q = 1'b0;  // было хотя бы одно начало кадра
  logic [7:0] since_q = '0, de_len_q = '0, lines_q = '0;
  logic de_rise, de_fall, frame_start;

  assign de_rise = !de_q && de;
  assign de_fall = de_q && !de;
  // Начало кадра — начало строки после гашения кадра.
  assign frame_start = de_rise && (!seen_q || since_q == 8'(FrameGap));

  always_ff @(posedge clk_i) begin
    if (!init_q) begin
      de_q <= de;
      if (de_rise) seen_q <= 1'b1;
      if (frame_start) frame_seen_q <= 1'b1;
      since_q  <= de_rise ? 8'd1 : since_q + 1'b1;
      de_len_q <= de ? de_len_q + 1'b1 : '0;
      if (frame_start) lines_q <= 8'd1;
      else if (de_rise) lines_q <= lines_q + 1'b1;
    end
  end

  always_comb begin
    if (!init_q) begin
      // Начала строк — через HTotal тактов, а через гашение кадра — через FrameGap.
      if (de_rise && seen_q) assert (since_q == 8'(HTotal) || since_q == 8'(FrameGap));
      if (seen_q) assert (since_q <= 8'(FrameGap));
      // Видимая часть строки — HActive тактов подряд.
      if (de_fall) assert (de_len_q == 8'(HActive));
      assert (de_len_q <= 8'(HActive));
      // В кадре VActive строк: гашение кадра наступает ровно после VActive-й строки.
      if (frame_seen_q) assert (lines_q <= 8'(VActive));
      if (de_rise && seen_q) assert ((since_q == 8'(FrameGap)) == (lines_q == 8'(VActive)));
      // Координаты: DE — ровно внутри видимой области.
      if (settled_q) assert (de == (x < HActive && y < VActive));
    end
  end

endmodule
