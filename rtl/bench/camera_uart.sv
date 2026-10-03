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
// Домены: clk_i — UART и команды; pclk_i — камера и обработка. Кадры переходят между доменами
// через двухтактовые кадровые буферы, флаги — через синхронизаторы переключением (toggle).
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
    parameter logic [NumStages*SelW-1:0] DefaultSel = '0
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
  localparam int unsigned AddrW  = $clog2(Pixels);
  localparam int unsigned CfgW   = NumStages + NumStages * SelW;

  if (NumStages > 8 || NumStages * SelW > 8) begin : g_check_config_width
    $error("camera_uart: chain configuration does not fit into the bytes of command 'c'");
  end

  // =========================================================================================
  // Домен clk_i: команды и UART.
  // =========================================================================================
  logic [NumStages-1:0] stage_en_q;
  logic [NumStages*SelW-1:0] kernel_sel_q;
  logic arm_tgl_q;  // переключается на каждый запрос кадра
  logic done_tgl;  // из домена PCLK: кадр захвачен
  logic frame_tgl;  // из домена PCLK: начало кадра камеры

  // Синхронизаторы флагов из домена PCLK.
  logic [2:0] done_sync_q, frame_sync_q;
  logic done_pulse, frame_pulse;

  always_ff @(posedge clk_i) begin
    done_sync_q  <= {done_sync_q[1:0], done_tgl};
    frame_sync_q <= {frame_sync_q[1:0], frame_tgl};
  end
  assign done_pulse  = done_sync_q[2] ^ done_sync_q[1];
  assign frame_pulse = frame_sync_q[2] ^ frame_sync_q[1];

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

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q          <= Idle;
      stage_en_q       <= DefaultEn;
      kernel_sel_q     <= DefaultSel;
      arm_tgl_q        <= 1'b0;
      rd_addr_q        <= '0;
      send_out_q       <= 1'b0;
      tx_valid_q       <= 1'b0;
      tx_data_q        <= '0;
      period_idx_q     <= '0;
      period_latched_q <= '0;
    end else begin
      if (tx_valid_q && tx_ready) tx_valid_q <= 1'b0;

      unique case (state_q)
        Idle: begin
          if (rx_valid) begin
            unique case (rx_data)
              "c":     state_q <= CfgEn;
              "f": begin
                arm_tgl_q <= ~arm_tgl_q;
                state_q   <= WaitFrame;
              end
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
            stage_en_q <= rx_data[NumStages-1:0];
            state_q    <= CfgSel;
          end
        end

        CfgSel: begin
          if (rx_valid) begin
            kernel_sel_q <= rx_data[NumStages*SelW-1:0];
            state_q      <= Idle;
          end
        end

        WaitFrame: begin
          if (done_pulse) begin
            rd_addr_q  <= '0;
            send_out_q <= 1'b0;
            state_q    <= SendRead;
          end else if (rx_valid) begin
            state_q <= Idle;  // отмена ожидания
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
  // Конфигурация меняется редко, поэтому переходит в домен PCLK через два триггера (кадр, во
  // время которого она сменилась, может быть смешанным); запрос кадра — переключением.
  logic [CfgW-1:0] cfg_meta_q, cfg_q;
  logic [2:0] arm_sync_q;
  logic arm_pulse;

  always_ff @(posedge pclk_i) begin
    cfg_meta_q <= {stage_en_q, kernel_sel_q};
    cfg_q      <= cfg_meta_q;
    arm_sync_q <= {arm_sync_q[1:0], arm_tgl_q};
  end
  assign arm_pulse = arm_sync_q[2] ^ arm_sync_q[1];

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

  // Захват: после запроса — ближайший серый кадр целиком и результат этого же кадра. Результат
  // отстаёт от входа меньше чем на кадр, поэтому первый sof на выходе цепочки после начала
  // захвата серого кадра — это его результат.
  logic armed_q, raw_on_q, out_wait_q, out_on_q;
  logic [AddrW-1:0] raw_cnt_q, out_cnt_q;
  logic raw_start, out_start, raw_we, out_we;
  logic done_tgl_q, frame_tgl_q;

  assign raw_start = armed_q && ready_o && gray_valid && gray_sof;
  assign out_start = out_wait_q && out_valid && out_sof;
  assign raw_we = gray_valid && (raw_start || raw_on_q);
  assign out_we = out_valid && (out_start || out_on_q);

  always_ff @(posedge pclk_i) begin
    if (rst_pclk_i) begin
      armed_q     <= 1'b0;
      raw_on_q    <= 1'b0;
      out_wait_q  <= 1'b0;
      out_on_q    <= 1'b0;
      raw_cnt_q   <= '0;
      out_cnt_q   <= '0;
      done_tgl_q  <= 1'b0;
      frame_tgl_q <= 1'b0;
    end else begin
      if (gray_valid && gray_sof) frame_tgl_q <= ~frame_tgl_q;
      if (arm_pulse) armed_q <= 1'b1;

      if (raw_start) begin
        armed_q    <= 1'b0;
        raw_on_q   <= 1'b1;
        out_wait_q <= 1'b1;
        raw_cnt_q  <= AddrW'(1);
      end else if (raw_on_q && gray_valid) begin
        if (raw_cnt_q == AddrW'(Pixels - 1)) raw_on_q <= 1'b0;
        raw_cnt_q <= raw_cnt_q + 1'b1;
      end

      if (out_start) begin
        out_wait_q <= 1'b0;
        out_on_q   <= 1'b1;
        out_cnt_q  <= AddrW'(1);
      end else if (out_on_q && out_valid) begin
        if (out_cnt_q == AddrW'(Pixels - 1)) begin
          out_on_q   <= 1'b0;
          done_tgl_q <= ~done_tgl_q;  // результат пишется последним
        end
        out_cnt_q <= out_cnt_q + 1'b1;
      end
    end
  end

  assign done_tgl  = done_tgl_q;
  assign frame_tgl = frame_tgl_q;
  assign frame_o   = frame_tgl_q;

  frame_buffer #(
      .Width (Width),
      .Height(Height)
  ) u_raw_buffer (
      .clk_w_i  (pclk_i),
      .rst_w_i  (rst_pclk_i),
      .valid_i  (raw_we),
      .sof_i    (raw_start),
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
      .sof_i    (out_start),
      .data_i   (out_data),
      .clk_r_i  (clk_i),
      .rd_addr_i(rd_addr_q),
      .rd_data_o(out_rdata)
  );

endmodule
