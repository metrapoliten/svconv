`timescale 1ns / 1ps

// ПЗУ ядер свёртки с загрузкой выбранного ядра в регистры.
//
// В ПЗУ лежат NumKernels записей по K*K + 1 байт (формат — kernel_rom_bytes() в модели):
// K*K весов построчно (дополнительный код), затем байт настройки {abs, 0, 0, 0, shift[3:0]}.
// Содержимое читается из InitFile ($readmemh), который генерирует model/gen_hex.py.
//
// После сброса и при каждой смене sel_i модуль по одному байту за такт читает запись ядра в
// промежуточный регистр и по её последнему байту разом обновляет weights_o, shift_o и abs_o;
// если sel_i меняется на другой существующий номер посреди загрузки, она начинается заново.
// При неизменном sel_i ready_o появляется не позже чем через K*K + 3 такта (доказано в
// formal/kernel_rom). Дальше веса берутся из регистров — ПЗУ не читается для каждого пикселя.
// ready_o = 1, когда выходы соответствуют sel_i.
//
// Номер ядра вне 0..NumKernels-1 (возможен, если NumKernels не степень двойки) не начинает
// загрузку, и пока он выбран, ready_o = 0. Загрузка, начатая до него, доводится до конца:
// выходы переключатся на ядро этой загрузки (ready_o при этом остаётся 0). Без начатой
// загрузки выходы сохраняют последнее загруженное ядро.
module kernel_rom #(
    parameter int unsigned K = 5,
    parameter int unsigned NumKernels = 3,
    // Нетипизированный: iverilog не передаёт параметры типа string во вложенные модули
    // внутри generate (см. conv_pipeline.sv).
    // verilog_lint: waive explicit-parameter-storage-type
    parameter InitFile = "kernels.hex",
    parameter int unsigned SelW = (NumKernels > 1) ? $clog2(NumKernels) : 1
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1

    input logic [SelW-1:0] sel_i,  // номер ядра (порядок — KERNEL_ROM_ORDER в модели)

    output logic [K*K*8-1:0] weights_o,  // вес (i, j): weights_o[(i*K + j)*8 +: 8]
    output logic [      3:0] shift_o,
    output logic             abs_o,
    output logic             ready_o
);

  localparam int unsigned NumWeights = K * K;
  localparam int unsigned Entry = NumWeights + 1;
  localparam int unsigned Depth = NumKernels * Entry;
  localparam int unsigned AddrW = $clog2(Depth);
  localparam int unsigned IdxW = $clog2(Entry + 1);

  logic [7:0] rom[Depth];

  logic sel_ok;
  assign sel_ok = int'(sel_i) < int'(NumKernels);

  initial $readmemh(InitFile, rom);

  // Синхронное чтение: байт по адресу addr_q появляется на rom_q на следующем такте.
  logic [AddrW-1:0] addr_q;
  logic [      7:0] rom_q;

  always_ff @(posedge clk_i) rom_q <= rom[addr_q];

  // Загрузка: rd_idx_q — номер байта записи, который сейчас на rom_q.
  logic loading_q;
  logic            loaded_q;  // в регистрах лежит какое-то ядро (после сброса — нет)
  logic [SelW-1:0] loaded_sel_q;
  logic [SelW-1:0] target_sel_q;
  logic [IdxW-1:0] issue_idx_q;  // сколько адресов уже выдано
  logic rd_valid_q;
  logic [IdxW-1:0] rd_idx_q;
  // Веса копятся в сдвиговом регистре: новый байт входит сверху, первый оказывается внизу.
  logic [K*K*8-1:0] stage_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      loading_q    <= 1'b0;
      loaded_q     <= 1'b0;
      loaded_sel_q <= '0;
      target_sel_q <= '0;
      issue_idx_q  <= '0;
      rd_valid_q   <= 1'b0;
      rd_idx_q     <= '0;
      addr_q       <= '0;
    end else if (!loading_q) begin
      rd_valid_q <= 1'b0;
      if (sel_ok && (!loaded_q || sel_i != loaded_sel_q)) begin
        loading_q    <= 1'b1;
        target_sel_q <= sel_i;
        addr_q       <= AddrW'(sel_i) * AddrW'(Entry);
        issue_idx_q  <= IdxW'(1);
        rd_valid_q   <= 1'b0;
      end
    end else if (sel_ok && sel_i != target_sel_q) begin
      // Выбор сменился посреди загрузки — начинаем загрузку нового ядра сразу (несуществующий
      // номер загрузку не прерывает).
      target_sel_q <= sel_i;
      addr_q       <= AddrW'(sel_i) * AddrW'(Entry);
      issue_idx_q  <= IdxW'(1);
      rd_valid_q   <= 1'b0;
    end else begin
      if (issue_idx_q != IdxW'(Entry)) begin
        addr_q      <= addr_q + 1'b1;
        issue_idx_q <= issue_idx_q + 1'b1;
      end
      // Данные идут на такт позже адресов.
      rd_valid_q <= 1'b1;
      rd_idx_q   <= rd_valid_q ? rd_idx_q + 1'b1 : '0;
      if (rd_valid_q && rd_idx_q == IdxW'(Entry - 1)) begin
        loading_q    <= 1'b0;
        loaded_q     <= 1'b1;
        loaded_sel_q <= target_sel_q;
        rd_valid_q   <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      weights_o <= '0;
      shift_o   <= '0;
      abs_o     <= 1'b0;
    end else if (rd_valid_q) begin
      if (rd_idx_q < IdxW'(NumWeights)) begin
        stage_q <= {rom_q, stage_q[K*K*8-1:8]};
      end else begin
        weights_o <= stage_q;
        shift_o   <= rom_q[3:0];
        abs_o     <= rom_q[7];
      end
    end
  end

  assign ready_o = sel_ok && loaded_q && !loading_q && (sel_i == loaded_sel_q);

`ifdef FORMAL
  // Инварианты для доказательства k-индукцией (formal/kernel_rom): без них решатель может
  // начать с недостижимого состояния — например, с мусора в выходных регистрах, пока выбран
  // несуществующий номер и загрузки нет. В такте сброса регистры ещё не определены.
  always_comb begin
    if (!rst_i) begin
      assert (int'(loaded_sel_q) < int'(NumKernels));
      assert (int'(target_sel_q) < int'(NumKernels));
      if (loaded_q && !loading_q) begin
        for (int i = 0; i < NumWeights; i++) begin
          assert (weights_o[i*8+:8] == rom[int'(loaded_sel_q)*Entry+i]);
        end
        assert (shift_o == rom[int'(loaded_sel_q)*Entry+NumWeights][3:0]);
        assert (abs_o == rom[int'(loaded_sel_q)*Entry+NumWeights][7]);
      end
    end
  end
`endif

endmodule
