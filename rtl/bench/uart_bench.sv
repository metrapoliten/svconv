`timescale 1ns / 1ps

// Стенд для проверки цепочки свёрток на плате без периферии.
//
// Тестовое изображение из ПЗУ (frame_rom_source) непрерывно, по пикселю в такт, проходит
// через conv_pipeline. Компьютер управляет стендом по UART (8N1) однобайтовыми командами:
//
//   'c' <en> <sel>  настроить цепочку: en — включённые каскады (бит s — каскад s),
//                   sel — номера ядер (каскад s — биты [s*SelW +: SelW]); ответа нет
//   'f'             прислать кадр: стенд дожидается загрузки ядер, пропускает текущий
//                   (возможно, смешанный после перенастройки) кадр, записывает следующий
//                   в буфер и отправляет Width*Height байт по строкам
//   'p'             прислать период выходных кадров в тактах — 4 байта, младший первым
//
// Пока стенд занят ответом (busy_o), новые команды игнорируются.
//
// Настройка из команды 'c' применяется, только если получены оба байта и все номера ядер
// допустимы (< NumKernels); иначе команда отбрасывается и остаётся прежняя цепочка. Если
// следующий байт команды 'c' не пришёл за CmdTimeoutBits битовых интервалов UART (~8,7 мс при
// 115200 бод), команда тоже отбрасывается — так потерянный байт не сдвигает разбор следующих
// команд. Компьютер восстанавливает обмен, выждав тишину на линии дольше этого времени.
module uart_bench #(
    parameter int unsigned Width = 160,
    parameter int unsigned Height = 120,
    parameter int unsigned K = 5,
    parameter int unsigned NumStages = 3,
    parameter int unsigned NumKernels = 3,
    parameter int unsigned ClkFreq = 27_000_000,
    parameter int unsigned Baud = 115_200,
    // Нетипизированные: см. conv_pipeline.sv.
    // verilog_lint: waive explicit-parameter-storage-type
    parameter ImageFile = "image.hex",
    // verilog_lint: waive explicit-parameter-storage-type
    parameter KernelFile = "kernels.hex",
    parameter int unsigned SelW = (NumKernels > 1) ? $clog2(NumKernels) : 1,
    // Конфигурация после сброса.
    parameter logic [NumStages-1:0] DefaultEn = '1,
    parameter logic [NumStages*SelW-1:0] DefaultSel = '0,
    // Сколько битовых интервалов UART ждать следующего байта незавершённой команды.
    parameter int unsigned CmdTimeoutBits = 1000
) (
    input  logic clk_i,
    input  logic rst_i,      // синхронный сброс, активный уровень 1
    input  logic uart_rx_i,
    output logic uart_tx_o,
    output logic ready_o,    // ядра всех каскадов загружены
    output logic busy_o      // стенд выполняет команду
);

  localparam int unsigned Pixels = Width * Height;
  localparam int unsigned AddrW = $clog2(Pixels);
  localparam int unsigned CmdTimeoutClks = CmdTimeoutBits * ((ClkFreq + Baud / 2) / Baud);
  localparam int unsigned CmdCntW = $clog2(CmdTimeoutClks + 1);

  // Настройка цепочки передаётся одним байтом на поле.
  if (NumStages > 8 || NumStages * SelW > 8) begin : g_check_config_width
    $error("uart_bench: chain configuration does not fit into the bytes of command 'c'");
  end

  // ---------------------------------------------------------------------------------------
  // Источник кадров и цепочка свёрток.
  // ---------------------------------------------------------------------------------------
  logic src_valid, src_sof;
  logic [7:0] src_data;

  frame_rom_source #(
      .Width    (Width),
      .Height   (Height),
      .ImageFile(ImageFile)
  ) u_source (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .valid_o(src_valid),
      .sof_o  (src_sof),
      .data_o (src_data)
  );

  logic [     NumStages-1:0] stage_en_q;
  logic [NumStages*SelW-1:0] kernel_sel_q;
  logic pipe_valid, pipe_sof;
  logic [7:0] pipe_data;

  conv_pipeline #(
      .Width     (Width),
      .Height    (Height),
      .K         (K),
      .NumStages (NumStages),
      .NumKernels(NumKernels),
      .KernelFile(KernelFile),
      .SelW      (SelW)
  ) u_pipeline (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .stage_en_i  (stage_en_q),
      .kernel_sel_i(kernel_sel_q),
      .ready_o     (ready_o),
      .valid_i     (src_valid),
      .sof_i       (src_sof),
      .data_i      (src_data),
      .valid_o     (pipe_valid),
      .sof_o       (pipe_sof),
      .data_o      (pipe_data)
  );

  // ---------------------------------------------------------------------------------------
  // Период выходных кадров: число тактов между соседними sof на выходе цепочки.
  // ---------------------------------------------------------------------------------------
  logic [31:0] period_cnt_q, period_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      period_cnt_q <= '0;
      period_q     <= '0;
    end else if (pipe_valid && pipe_sof) begin
      period_q     <= period_cnt_q;
      period_cnt_q <= 32'd1;
    end else begin
      period_cnt_q <= period_cnt_q + 1'b1;
    end
  end

  // ---------------------------------------------------------------------------------------
  // UART.
  // ---------------------------------------------------------------------------------------
  logic [7:0] rx_data;
  logic       rx_valid;

  uart_rx #(
      .ClkFreq(ClkFreq),
      .Baud   (Baud)
  ) u_uart_rx (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .rx_i   (uart_rx_i),
      .data_o (rx_data),
      .valid_o(rx_valid)
  );

  logic [7:0] tx_data_q;
  logic       tx_valid_q;
  logic       tx_ready;

  uart_tx #(
      .ClkFreq(ClkFreq),
      .Baud   (Baud)
  ) u_uart_tx (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .data_i (tx_data_q),
      .valid_i(tx_valid_q),
      .ready_o(tx_ready),
      .tx_o   (uart_tx_o)
  );

  // ---------------------------------------------------------------------------------------
  // Буфер кадра: запись с выхода цепочки, чтение для отправки.
  // ---------------------------------------------------------------------------------------
  logic [AddrW-1:0] wr_addr_q, rd_addr_q;
  logic       cap_we;
  logic [7:0] cap_rdata;

  sdp_ram #(
      .Depth(Pixels),
      .DataW(8)
  ) u_capture (
      .clk_i  (clk_i),
      .we_i   (cap_we),
      .waddr_i(wr_addr_q),
      .wdata_i(pipe_data),
      .raddr_i(rd_addr_q),
      .rdata_o(cap_rdata)
  );

  // ---------------------------------------------------------------------------------------
  // Автомат команд.
  // ---------------------------------------------------------------------------------------
  typedef enum logic [3:0] {
    Idle,
    CfgEn,  // ждём байт en команды 'c'
    CfgSel,  // ждём байт sel команды 'c'
    WaitFirst,    // 'f': ждём загрузки ядер и начала текущего кадра
    WaitSecond,  // 'f': пропускаем текущий кадр
    Capture,  // 'f': записываем кадр в буфер
    SendRead,  // 'f': читаем байт буфера
    SendWait,  // 'f': отдаём байт передатчику
    SendPeriod  // 'p': отправляем 4 байта периода
  } state_e;

  state_e state_q;
  logic [1:0] period_idx_q;
  logic [31:0] period_latched_q;
  logic [NumStages-1:0] pending_en_q;  // байт en команды 'c' до прихода байта sel
  logic [CmdCntW-1:0] cmd_wait_q;  // тактов без байта внутри незавершённой команды

  // Все номера ядер в байте sel существуют.
  function automatic logic sel_valid(input logic [NumStages*SelW-1:0] sel);
    for (int s = 0; s < NumStages; s++) begin
      if (int'(sel[s*SelW+:SelW]) >= int'(NumKernels)) return 1'b0;
    end
    return 1'b1;
  endfunction

  // Пиксель кадра записывается в буфер в состоянии Capture, а первый пиксель — в тот же
  // такт, когда приходит его sof (переход из WaitSecond).
  assign cap_we = pipe_valid && ((state_q == Capture) || (state_q == WaitSecond && pipe_sof));

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q          <= Idle;
      stage_en_q       <= DefaultEn;
      kernel_sel_q     <= DefaultSel;
      wr_addr_q        <= '0;
      rd_addr_q        <= '0;
      tx_valid_q       <= 1'b0;
      tx_data_q        <= '0;
      period_idx_q     <= '0;
      period_latched_q <= '0;
      pending_en_q     <= '0;
      cmd_wait_q       <= '0;
    end else begin
      if (tx_valid_q && tx_ready) tx_valid_q <= 1'b0;
      cmd_wait_q <= (rx_valid || state_q == Idle) ? '0 : cmd_wait_q + 1'b1;

      unique case (state_q)
        Idle: begin
          if (rx_valid) begin
            unique case (rx_data)
              "c":     state_q <= CfgEn;
              "f":     state_q <= WaitFirst;
              "p": begin
                period_latched_q <= period_q;
                period_idx_q     <= '0;
                state_q          <= SendPeriod;
              end
              default: ;
            endcase
          end
        end

        CfgEn: begin
          if (rx_valid) begin
            pending_en_q <= rx_data[NumStages-1:0];
            state_q      <= CfgSel;
          end else if (cmd_wait_q == CmdCntW'(CmdTimeoutClks)) begin
            state_q <= Idle;  // команда оборвалась
          end
        end

        CfgSel: begin
          if (rx_valid) begin
            if (sel_valid(rx_data[NumStages*SelW-1:0])) begin
              stage_en_q   <= pending_en_q;
              kernel_sel_q <= rx_data[NumStages*SelW-1:0];
            end
            state_q <= Idle;
          end else if (cmd_wait_q == CmdCntW'(CmdTimeoutClks)) begin
            state_q <= Idle;
          end
        end

        WaitFirst: begin
          if (ready_o && pipe_valid && pipe_sof) begin
            wr_addr_q <= '0;
            state_q   <= WaitSecond;
          end
        end

        WaitSecond: begin
          if (pipe_valid && pipe_sof) begin
            wr_addr_q <= AddrW'(1);
            state_q   <= Capture;
          end
        end

        Capture: begin
          if (pipe_valid) begin
            if (wr_addr_q == AddrW'(Pixels - 1)) begin
              rd_addr_q <= '0;
              state_q   <= SendRead;
            end else begin
              wr_addr_q <= wr_addr_q + 1'b1;
            end
          end
        end

        // Адрес выставлен; данные буфера будут на следующем такте.
        SendRead: state_q <= SendWait;

        SendWait: begin
          if (!tx_valid_q) begin
            tx_data_q  <= cap_rdata;
            tx_valid_q <= 1'b1;
            if (rd_addr_q == AddrW'(Pixels - 1)) begin
              state_q <= Idle;
            end else begin
              rd_addr_q <= rd_addr_q + 1'b1;
              state_q   <= SendRead;
            end
          end
        end

        SendPeriod: begin
          if (!tx_valid_q) begin
            tx_data_q    <= period_latched_q[8*period_idx_q+:8];
            tx_valid_q   <= 1'b1;
            period_idx_q <= period_idx_q + 1'b1;
            if (period_idx_q == 2'd3) state_q <= Idle;
          end
        end

        default: state_q <= Idle;
      endcase
    end
  end

  assign busy_o = (state_q != Idle) || tx_valid_q || !tx_ready;

endmodule
