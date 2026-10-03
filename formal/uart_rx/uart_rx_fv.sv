`timescale 1ns / 1ps

// Ограниченная формальная проверка (BMC) uart_rx в паре с uart_tx: для любой
// последовательности байт и пауз приёмник выдаёт каждый переданный байт ровно один раз, без искажений и не позднее чем
// через кадр после начала передачи, и не выдаёт ничего лишнего.
module uart_rx_fv (
    input logic       clk_i,
    input logic       rst_i,
    input logic [7:0] data_i,
    input logic       valid_i
);

  localparam int unsigned ClksPerBit = 8;
  // Передача кадра — 10 бит; приёмник выдаёт байт в середине стоп-бита, плюс задержка
  // синхронизатора и регистров.
  localparam int unsigned MaxLatency = 10 * ClksPerBit + 4;

  logic tx_ready, line, rx_valid;
  logic [7:0] rx_data;

  uart_tx #(
      .ClkFreq(ClksPerBit),
      .Baud   (1)
  ) u_tx (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .data_i (data_i),
      .valid_i(valid_i),
      .ready_o(tx_ready),
      .tx_o   (line)
  );

  uart_rx #(
      .ClkFreq(ClksPerBit),
      .Baud   (1)
  ) dut (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .rx_i   (line),
      .data_o (rx_data),
      .valid_o(rx_valid)
  );

  // Первые такты — сброс (синхронизатору приёмника нужно 2 такта, чтобы увидеть линию в 1).
  logic [1:0] init_q = '0;
  always_ff @(posedge clk_i) if (init_q != 2'd3) init_q <= init_q + 1'b1;
  always_comb if (init_q != 2'd3) assume (rst_i);
  always_comb if (init_q == 2'd3) assume (!rst_i);

  // Наблюдатель: байт в пути и сколько тактов он в пути.
  logic       pending_q;
  logic [7:0] sent_q;
  logic [9:0] frame_q;  // {стоп, данные, старт}
  logic [7:0] age_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      pending_q <= 1'b0;
      age_q     <= '0;
    end else begin
      if (rx_valid) pending_q <= 1'b0;
      if (valid_i && tx_ready) begin
        pending_q <= 1'b1;
        sent_q    <= data_i;
        frame_q   <= {1'b1, data_i, 1'b0};
        age_q     <= '0;
      end else if (pending_q) begin
        age_q <= age_q + 1'b1;
      end
    end
  end

  always_comb begin
    if (init_q == 2'd3) begin
      // Байт выдаётся только если он был отправлен, и ровно тот, что отправлен.
      if (rx_valid) assert (pending_q && rx_data == sent_q);
      // Следующий байт уходит только после того, как предыдущий принят.
      if (valid_i && tx_ready) assert (!pending_q || rx_valid);
      // Байт принимается не позднее MaxLatency тактов.
      if (pending_q) assert (age_q <= 8'(MaxLatency));
      // Вспомогательные инварианты для индукции (отсекают недостижимые состояния):
      // пока байт в пути, передатчик занят, а на линии — очередной бит кадра (выход uart_tx
      // регистровый и отстаёт на такт; свойство доказано в formal/uart_tx).
      // Приёмник выдаёт байт не позже такта, в котором передатчик освобождается.
      if (tx_ready) assert (!pending_q || rx_valid);
      if (pending_q && age_q >= 1 && age_q <= 8'(10 * ClksPerBit))
        assert (line == frame_q[(age_q-1)/ClksPerBit]);
    end
  end

endmodule
