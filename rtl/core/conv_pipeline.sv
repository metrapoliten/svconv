`timescale 1ns / 1ps

// Цепочка из NumStages каскадов свёртки (по умолчанию: размытие -> размытие -> границы).
//
// Каждый каскад s берёт ядро номер kernel_sel_i[s*SelW +: SelW] из своего ПЗУ ядер
// (kernel_rom) и может быть выключен: при stage_en_i[s] = 0 поток проходит каскад без
// изменений. Результат совпадает с pipeline() из модели для списка включённых ядер.
//
// Поток — как у conv2d_stage: valid/sof/data, пиксель в любом такте, паузы допустимы.
// Смена конфигурации (stage_en_i, kernel_sel_i) действует сразу на пиксели, которые в этот
// момент вычисляются, а не с границы кадра. Нижние p + 1 строк каждого кадра (p = K / 2)
// вычисляются, пока на вход уже идёт следующий кадр, поэтому при непрерывном потоке момента,
// когда смена не задевает ни одного кадра, нет: портятся выходной кадр, идущий в момент смены,
// и хвост предыдущего; каскады цепочки к тому же видят смену в разных местах своих кадров.
// После смены ядра каскад несколько тактов загружает новые веса; ready_o = 1, когда все
// каскады работают с выбранными ядрами. Каскад, вход которого переключился (обход <-> свёртка
// предыдущего каскада), до первого sof на новом входе считает позицию в старой фазе и может
// выдать лишний sof; переключилось несколько каскадов — лишних sof_o может быть несколько,
// поэтому кадры на выходе после смены считать нельзя. Считаются кадры на входе: чистым
// гарантированно будет выходной кадр, который начнётся первым после второго sof_i, пришедшего
// после смены при ready_o = 1. Первый входной кадр выравнивает все каскады, и его результат
// выходит раньше начала второго, если кадр длиннее задержки цепочки — так всегда при
// Height > NumStages * (p + 1). Так ждёт тест tests/camera_lcd_top_modes.
module conv_pipeline #(
    parameter int unsigned Width = 160,
    parameter int unsigned Height = 120,
    parameter int unsigned K = 5,
    parameter int unsigned NumStages = 3,
    parameter int unsigned NumKernels = 3,
    // Файл инициализации ПЗУ ядер; нетипизированный, т.к. iverilog не передаёт параметры типа
    // string во вложенные модули внутри generate.
    // verilog_lint: waive explicit-parameter-storage-type
    parameter KernelFile = "kernels.hex",
    // Разрядность номера ядра — определяется числом ядер.
    localparam int unsigned SelW = (NumKernels > 1) ? $clog2(NumKernels) : 1
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1

    input  logic [     NumStages-1:0] stage_en_i,
    input  logic [NumStages*SelW-1:0] kernel_sel_i,
    output logic                      ready_o,

    input logic       valid_i,
    input logic       sof_i,
    input logic [7:0] data_i,

    output logic       valid_o,
    output logic       sof_o,
    output logic [7:0] data_o
);

  // Поток между каскадами: индекс s — вход каскада s, индекс NumStages — выход цепочки.
  // Связи — цепи (wire): каждый элемент задаётся одним continuous assign.
  wire                  valid       [NumStages+1];
  wire                  sof         [NumStages+1];
  wire  [          7:0] data        [NumStages+1];
  logic [NumStages-1:0] stage_ready;

  assign valid[0] = valid_i;
  assign sof[0]   = sof_i;
  assign data[0]  = data_i;

  for (genvar s = 0; s < NumStages; s++) begin : g_stage
    logic [K*K*8-1:0] weights;
    logic [      3:0] shift;
    logic             abs_mode;
    logic conv_valid, conv_sof;
    logic [7:0] conv_data;

    kernel_rom #(
        .K(K),
        .NumKernels(NumKernels),
        .InitFile(KernelFile)
    ) u_kernel_rom (
        .clk_i    (clk_i),
        .rst_i    (rst_i),
        .sel_i    (kernel_sel_i[s*SelW+:SelW]),
        .weights_o(weights),
        .shift_o  (shift),
        .abs_o    (abs_mode),
        .ready_o  (stage_ready[s])
    );

    conv2d_stage #(
        .Width (Width),
        .Height(Height),
        .K     (K)
    ) u_conv (
        .clk_i    (clk_i),
        .rst_i    (rst_i),
        .weights_i(weights),
        .shift_i  (shift),
        .abs_i    (abs_mode),
        .valid_i  (valid[s]),
        .sof_i    (sof[s]),
        .data_i   (data[s]),
        .valid_o  (conv_valid),
        .sof_o    (conv_sof),
        .data_o   (conv_data)
    );

    // Выход каскада (или обход) регистрируется, чтобы мультиплексор не удлинял путь.
    logic out_valid_q, out_sof_q;
    logic [7:0] out_data_q;

    always_ff @(posedge clk_i) begin
      if (rst_i) begin
        out_valid_q <= 1'b0;
        out_sof_q   <= 1'b0;
      end else if (stage_en_i[s]) begin
        out_valid_q <= conv_valid;
        out_sof_q   <= conv_sof;
      end else begin
        out_valid_q <= valid[s];
        out_sof_q   <= sof[s];
      end
      out_data_q <= stage_en_i[s] ? conv_data : data[s];
    end

    assign valid[s+1] = out_valid_q;
    assign sof[s+1]   = out_sof_q;
    assign data[s+1]  = out_data_q;
  end

  assign ready_o = &stage_ready;
  assign valid_o = valid[NumStages];
  assign sof_o   = sof[NumStages];
  assign data_o  = data[NumStages];

endmodule
