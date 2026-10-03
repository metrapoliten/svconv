`timescale 1ns / 1ps

// Формальная проверка video_timing: выходы, измеренные снаружи, соответствуют параметрам.
// Параметры уменьшены, чтобы доказательство было быстрым; полярность синхроимпульсов —
// активный 0, как у дисплеев проекта.
module video_timing_fv (
    input logic clk_i,
    input logic rst_i
);

  localparam int unsigned HActive = 3, HFront = 1, HSync = 2, HBack = 1;
  localparam int unsigned VActive = 2, VFront = 1, VSync = 1, VBack = 1;
  localparam int unsigned HTotal = HActive + HFront + HSync + HBack;
  localparam int unsigned VTotal = VActive + VFront + VSync + VBack;
  localparam int unsigned FrameClks = HTotal * VTotal;

  logic hsync, vsync, de;
  logic [$clog2(HTotal)-1:0] x;
  logic [$clog2(VTotal)-1:0] y;

  video_timing #(
      .HActive (HActive),
      .HFront  (HFront),
      .HSync   (HSync),
      .HBack   (HBack),
      .VActive (VActive),
      .VFront  (VFront),
      .VSync   (VSync),
      .VBack   (VBack),
      .HSyncPol(1'b0),
      .VSyncPol(1'b0)
  ) dut (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .hsync_o(hsync),
      .vsync_o(vsync),
      .de_o   (de),
      .x_o    (x),
      .y_o    (y)
  );

  // Сброс в первом такте, дальше — без сброса.
  logic init_q = 1'b1;
  always_ff @(posedge clk_i) init_q <= 1'b0;
  always_comb assume (rst_i == init_q);

  // Наблюдатель.
  logic hs_q = 1'b1, vs_q = 1'b1, de_q = 1'b0;
  logic
      h_seen_q = 1'b0, v_seen_q = 1'b0;  // был хотя бы один спад импульса
  logic [7:0] since_hs_q = '0, hs_len_q = '0, de_len_q = '0;
  logic [7:0] since_vs_q = '0, vs_len_q = '0, de_frame_q = '0;
  logic hs_fall, hs_rise, vs_fall, vs_rise, de_fall;

  assign hs_fall = hs_q && !hsync;
  assign hs_rise = !hs_q && hsync;
  assign vs_fall = vs_q && !vsync;
  assign vs_rise = !vs_q && vsync;
  assign de_fall = de_q && !de;

  always_ff @(posedge clk_i) begin
    if (!init_q) begin
      hs_q <= hsync;
      vs_q <= vsync;
      de_q <= de;
      if (hs_fall) h_seen_q <= 1'b1;
      if (vs_fall) v_seen_q <= 1'b1;
      since_hs_q <= hs_fall ? 8'd1 : since_hs_q + 1'b1;
      since_vs_q <= vs_fall ? 8'd1 : since_vs_q + 1'b1;
      hs_len_q   <= !hsync ? hs_len_q + 1'b1 : '0;
      vs_len_q   <= !vsync ? vs_len_q + 1'b1 : '0;
      de_len_q   <= de ? de_len_q + 1'b1 : '0;
      de_frame_q <= vs_fall ? 8'(de) : de_frame_q + 8'(de);
    end
  end

  always_comb begin
    if (!init_q) begin
      // Период строки и кадра — между соседними спадами синхроимпульсов.
      if (hs_fall && h_seen_q) assert (since_hs_q == 8'(HTotal));
      if (vs_fall && v_seen_q) assert (since_vs_q == 8'(FrameClks));
      if (h_seen_q) assert (since_hs_q <= 8'(HTotal));
      if (v_seen_q) assert (since_vs_q <= 8'(FrameClks));
      // Длительности импульсов.
      if (hs_rise) assert (hs_len_q == 8'(HSync));
      if (vs_rise) assert (vs_len_q == 8'(VSync * HTotal));
      assert (hs_len_q <= 8'(HSync));
      assert (vs_len_q <= 8'(VSync * HTotal));
      // Видимая часть строки — HActive тактов подряд, в кадре — HActive*VActive пикселей.
      if (de_fall) assert (de_len_q == 8'(HActive));
      assert (de_len_q <= 8'(HActive));
      if (vs_fall && v_seen_q) assert (de_frame_q == 8'(HActive * VActive));
      // Во время синхроимпульса строки изображения нет.
      if (!hsync) assert (!de);
    end
  end

endmodule
