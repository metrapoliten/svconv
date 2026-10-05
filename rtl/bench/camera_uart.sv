`timescale 1ns / 1ps

// Стенд для проверки камеры и цепочки свёрток без дисплея: кадры передаются на компьютер по UART.
//
// В домене PCLK работает camera_pipeline. По команде компьютера захватывается один кадр
// камеры в двух видах — серый кадр до свёрток и результат цепочки для этого же кадра, — и оба
// отправляются по UART: компьютер показывает их и сверяет результат с моделью, применённой к
// серому кадру. Команды (UART 8N1, по байту):
//
//   'c' <en> <sel>  настроить цепочку (как в uart_bench); ответа нет
//   'f'             захватить кадр: Width*Height байт серого кадра, затем Width*Height байт
//                   результата, по строкам. Пока кадр не захвачен (камера не работает),
//                   любой принятый байт отменяет ожидание
//   'p'             период кадров камеры в тактах clk_i — 4 байта, младший первым
//
// Пока стенд занят (busy_o = 1, в том числе пока передаётся последний байт ответа), новые
// команды игнорируются (кроме отмены ожидания кадра, см. выше).
//
// Настройка из команды 'c' применяется, только если получены оба байта и все номера ядер
// допустимы (< NumKernels); иначе команда отбрасывается. Незавершённая команда 'c'
// отбрасывается, если следующий байт не пришёл за CmdTimeoutBits битовых интервалов UART
// (~8,7 мс при 115200 бод). Компьютер восстанавливает обмен так: посылает байт, отменяющий
// ожидание кадра (например, 'x'), и выжидает тишину на линии дольше этого времени.
//
// Домены: clk_i — UART и команды; pclk_i — камера и обработка. Кадры переходят между доменами
// через двухтактовые кадровые буферы, запрос кадра — рукопожатием уровнями (capture_ctrl),
// начало кадра камеры — через pulse_sync, настройки — через level_sync.
module camera_uart #(
    parameter int unsigned Width = 160,
    parameter int unsigned Height = 120,
    parameter int unsigned Factor = 4,
    parameter int unsigned K = 5,
    parameter int unsigned NumStages = 3,
    parameter int unsigned NumKernels = 3,
    // Нетипизированный: см. conv_pipeline.sv.
    // verilog_lint: waive explicit-parameter-storage-type
    parameter KernelFile = "kernels.hex",
    parameter int unsigned SelW = (NumKernels > 1) ? $clog2(NumKernels) : 1,
    parameter int unsigned ClkFreq = 27_000_000,
    parameter int unsigned Baud = 115_200,
    parameter logic [NumStages-1:0] DefaultEn = '1,
    parameter logic [NumStages*SelW-1:0] DefaultSel = '0,
    // Сколько битовых интервалов UART ждать следующего байта незавершённой команды.
    parameter int unsigned CmdTimeoutBits = 1000
) (
    input  logic clk_i,
    input  logic rst_i,      // синхронный сброс домена clk_i
    input  logic uart_rx_i,
    output logic uart_tx_o,
    output logic busy_o,     // стенд выполняет команду

    input logic pclk_i,
    input logic rst_pclk_i,  // синхронный сброс домена PCLK
    input logic cam_vsync_i,
    input logic cam_href_i,
    input logic [7:0] cam_data_i,
    output logic ready_o,  // ядра загружены (домен PCLK)
    output logic       frame_o       // переключается на каждом кадре камеры (домен PCLK)
);

  localparam int unsigned Pixels = Width * Height;
  localparam int unsigned AddrW = $clog2(Pixels);
  localparam int unsigned CfgW = NumStages + NumStages * SelW;
  localparam int unsigned CmdTimeoutClks = CmdTimeoutBits * ((ClkFreq + Baud / 2) / Baud);
  localparam int unsigned CmdCntW = $clog2(CmdTimeoutClks + 1);

  if (NumStages > 8 || NumStages * SelW > 8) begin : g_check_config_width
    $error("camera_uart: chain configuration does not fit into the bytes of command 'c'");
  end

  // =========================================================================================
  // Домен clk_i: команды и UART.
  // =========================================================================================
  logic [NumStages-1:0] stage_en_q;
  logic [NumStages*SelW-1:0] kernel_sel_q;
  logic cap_done;  // кадр захвачен (capture_ctrl)
  logic frame_pulse;  // начало кадра камеры (импульс из домена PCLK)

  // Период кадров камеры в тактах clk_i.
  logic [31:0] period_cnt_q, period_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      period_cnt_q <= '0;
      period_q     <= '0;
    end else if (frame_pulse) begin
      period_q     <= period_cnt_q;
      period_cnt_q <= 32'd1;
    end else begin
      period_cnt_q <= period_cnt_q + 1'b1;
    end
  end

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

  // Чтение кадровых буферов (данные — на следующем такте).
  logic [AddrW-1:0] rd_addr_q;
  logic [7:0] raw_rdata, out_rdata;
  logic       send_out_q;  // отправляется результат (иначе — серый кадр)

  typedef enum logic [2:0] {
    Idle,
    CfgEn,
    CfgSel,
    WaitFrame,
    SendRead,
    SendWait,
    SendPeriod
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

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q          <= Idle;
      stage_en_q       <= DefaultEn;
      kernel_sel_q     <= DefaultSel;
      rd_addr_q        <= '0;
      send_out_q       <= 1'b0;
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
        // Команда принимается, только когда стенд свободен: busy_o = 0 (в Idle — передатчик
        // закончил ответ, включая его последний байт).
        Idle: begin
          if (rx_valid && !busy_o) begin
            unique case (rx_data)
              "c":     state_q <= CfgEn;
              "f":     state_q <= WaitFrame;
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

        // Ожидание отменяется любым байтом (захват в домене PCLK тоже прерывается).
        WaitFrame: begin
          if (rx_valid) begin
            state_q <= Idle;
          end else if (cap_done) begin
            rd_addr_q  <= '0;
            send_out_q <= 1'b0;
            state_q    <= SendRead;
          end
        end

        // Адрес выставлен; данные буфера будут на следующем такте.
        SendRead: state_q <= SendWait;

        SendWait: begin
          if (!tx_valid_q) begin
            tx_data_q  <= send_out_q ? out_rdata : raw_rdata;
            tx_valid_q <= 1'b1;
            if (rd_addr_q != AddrW'(Pixels - 1)) begin
              rd_addr_q <= rd_addr_q + 1'b1;
              state_q   <= SendRead;
            end else if (!send_out_q) begin
              rd_addr_q  <= '0;
              send_out_q <= 1'b1;
              state_q    <= SendRead;
            end else begin
              state_q <= Idle;
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

  // =========================================================================================
  // Домен PCLK: обработка и захват кадра.
  // =========================================================================================
  // Конфигурация меняется редко, поэтому переходит в домен PCLK синхронизатором уровня; запрос
  // кадра — рукопожатием (capture_ctrl).
  logic [CfgW-1:0] cfg_q;

  level_sync #(
      .Width(CfgW)
  ) u_cfg_sync (
      .clk_i(pclk_i),
      .d_i  ({stage_en_q, kernel_sel_q}),
      .q_o  (cfg_q)
  );

  logic gray_valid, gray_sof, out_valid, out_sof;
  logic [7:0] gray_data, out_data;

  camera_pipeline #(
      .Width     (Width),
      .Height    (Height),
      .Factor    (Factor),
      .K         (K),
      .NumStages (NumStages),
      .NumKernels(NumKernels),
      .KernelFile(KernelFile),
      .SelW      (SelW)
  ) u_camera (
      .pclk_i      (pclk_i),
      .rst_i       (rst_pclk_i),
      .cam_vsync_i (cam_vsync_i),
      .cam_href_i  (cam_href_i),
      .cam_data_i  (cam_data_i),
      .stage_en_i  (cfg_q[CfgW-1-:NumStages]),
      .kernel_sel_i(cfg_q[NumStages*SelW-1:0]),
      .ready_o     (ready_o),
      .gray_valid_o(gray_valid),
      .gray_sof_o  (gray_sof),
      .gray_data_o (gray_data),
      .out_valid_o (out_valid),
      .out_sof_o   (out_sof),
      .out_data_o  (out_data)
  );

  // Захват — только кадра, целиком прошедшего при текущей конфигурации. Сразу после её смены
  // выход цепочки ненадёжен: у каскада, вход которого переключился (обход <-> свёртка
  // предыдущего каскада), счётчики позиции до первого sof на новом входе идут в старой фазе и
  // могут выдать лишний sof_o — а захват результата начинается с первого sof после начала
  // серого кадра. Поэтому после смены конфигурации (или пока ядра грузятся) ждём один кадр
  // камеры: захват начнётся не раньше второго серого sof при ready, и результат будет первым
  // кадром на выходе после него — по контракту conv_pipeline.sv он чистый.
  logic [CfgW-1:0] cfg_prev_q;
  logic settled_q;

  always_ff @(posedge pclk_i) begin
    cfg_prev_q <= cfg_q;
    if (rst_pclk_i || cfg_q != cfg_prev_q || !ready_o) settled_q <= 1'b0;
    else if (gray_valid && gray_sof) settled_q <= 1'b1;
  end

  // Захват кадра по запросу.
  logic raw_we, raw_sof, out_we, out_sof_w;

  capture_ctrl #(
      .Pixels(Pixels)
  ) u_capture (
      .clk_i      (clk_i),
      .rst_i      (rst_i),
      .wait_i     (state_q == WaitFrame),
      .done_o     (cap_done),
      .pclk_i     (pclk_i),
      .rst_pclk_i (rst_pclk_i),
      .ready_i    (ready_o && settled_q),
      .in_valid_i (gray_valid),
      .in_sof_i   (gray_sof),
      .out_valid_i(out_valid),
      .out_sof_i  (out_sof),
      .raw_we_o   (raw_we),
      .raw_sof_o  (raw_sof),
      .out_we_o   (out_we),
      .out_sof_o  (out_sof_w)
  );

  // Переключается на каждом кадре камеры (светодиод).
  logic frame_tgl_q;

  always_ff @(posedge pclk_i) begin
    if (rst_pclk_i) frame_tgl_q <= 1'b0;
    else if (gray_valid && gray_sof) frame_tgl_q <= ~frame_tgl_q;
  end

  assign frame_o = frame_tgl_q;

  pulse_sync u_frame_sync (
      .src_clk_i  (pclk_i),
      .src_pulse_i(gray_valid && gray_sof),
      .dst_clk_i  (clk_i),
      .dst_pulse_o(frame_pulse)
  );

  frame_buffer #(
      .Width (Width),
      .Height(Height)
  ) u_raw_buffer (
      .clk_w_i  (pclk_i),
      .rst_w_i  (rst_pclk_i),
      .valid_i  (raw_we),
      .sof_i    (raw_sof),
      .data_i   (gray_data),
      .clk_r_i  (clk_i),
      .rd_addr_i(rd_addr_q),
      .rd_data_o(raw_rdata)
  );

  frame_buffer #(
      .Width (Width),
      .Height(Height)
  ) u_out_buffer (
      .clk_w_i  (pclk_i),
      .rst_w_i  (rst_pclk_i),
      .valid_i  (out_we),
      .sof_i    (out_sof_w),
      .data_i   (out_data),
      .clk_r_i  (clk_i),
      .rd_addr_i(rd_addr_q),
      .rd_data_o(out_rdata)
  );

endmodule
