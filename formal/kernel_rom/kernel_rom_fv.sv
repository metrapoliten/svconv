`timescale 1ns / 1ps

// Формальная проверка kernel_rom при любой последовательности выбора ядра:
//   - когда ready_o = 1, выходы равны записи выбранного ядра в ПЗУ.
// Содержимое ПЗУ — случайные байты (rom.hex, model/gen_hex.py random): у ядер проекта веса
// симметричны, и на них не видна, например, перестановка весов в обратном порядке.
//   - если выбор не меняется, ready_o появляется не позже чем через K*K + 3 такта (в том числе
//     когда выбор сменился посреди загрузки другого ядра);
//   - при несуществующем номере ядра (3 при NumKernels = 3) ready_o = 0.
// Индукция опирается на инварианты внутри kernel_rom.sv (блок `ifdef FORMAL): выходы
// соответствуют загруженному ядру, номера загруженного и загружаемого ядер существуют.
module kernel_rom_fv (
    input logic       clk_i,
    input logic       rst_i,
    input logic [1:0] sel_i
);

  localparam int unsigned K = 5, NumKernels = 3;
  localparam int unsigned Entry = K * K + 1;
  localparam int unsigned MaxLoad = K * K + 3;

  logic [K*K*8-1:0] weights;
  logic [3:0] shift;
  logic abs_mode, ready;

  kernel_rom #(
      .K         (K),
      .NumKernels(NumKernels),
      .InitFile  ("rom.hex")
  ) dut (
      .clk_i    (clk_i),
      .rst_i    (rst_i),
      .sel_i    (sel_i),
      .weights_o(weights),
      .shift_o  (shift),
      .abs_o    (abs_mode),
      .ready_o  (ready)
  );

  logic init_q = 1'b1;
  always_ff @(posedge clk_i) init_q <= 1'b0;
  always_comb assume (rst_i == init_q);

  // Эталон — то же содержимое ПЗУ.
  logic [7:0] rom[NumKernels*Entry];
  initial $readmemh("rom.hex", rom);

  logic [1:0] sel_q = '0;
  logic [7:0] wait_q = '0;  // тактов подряд без ready при неизменном допустимом выборе
  logic sel_ok;
  assign sel_ok = sel_i < 2'(NumKernels);

  always_ff @(posedge clk_i) begin
    sel_q  <= sel_i;
    // Такт сброса не считается: загрузка начинается после него.
    wait_q <= (rst_i || ready || !sel_ok || sel_i != sel_q) ? '0 : wait_q + 1'b1;
  end

  always_comb begin
    if (!init_q) begin
      if (ready) begin
        for (int i = 0; i < K * K; i++) assert (weights[i*8+:8] == rom[sel_i*Entry+i]);
        assert (shift == rom[sel_i*Entry+K*K][3:0]);
        assert (abs_mode == rom[sel_i*Entry+K*K][7]);
      end
      assert (wait_q <= 8'(MaxLoad));
      if (!sel_ok) assert (!ready);
    end
  end

endmodule
