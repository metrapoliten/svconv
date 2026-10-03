`timescale 1ns / 1ps

// Тест uart_rx: 1) приём байт подряд от uart_tx; 2) приём от «чужого» передатчика,
// скорость которого отличается на ±3%; 3) короткая помеха на линии не даёт ложного байта;
// 4) байт с ошибкой кадра (стоп-бит 0) отбрасывается.
module uart_rx_tb;

  localparam int unsigned ClkFreq = 1600;
  localparam int unsigned Baud = 100;  // 16 тактов на бит
  localparam int unsigned ClksPerBit = ClkFreq / Baud;
  localparam int unsigned NumBytes = 6;
  // Байт i — Bytes[8*i+:8]: 00, FF, A5, 5A, 01, 80.
  localparam logic [8*NumBytes-1:0] Bytes = 48'h80_01_5A_A5_FF_00;

  logic clk = 1'b0;
  logic rst = 1'b1;

  always #5 clk = ~clk;

  // Передатчик проекта.
  logic [7:0] tx_data;
  logic tx_valid = 1'b0, tx_ready, tx_line;

  uart_tx #(
      .ClkFreq(ClkFreq),
      .Baud   (Baud)
  ) u_tx (
      .clk_i  (clk),
      .rst_i  (rst),
      .data_i (tx_data),
      .valid_i(tx_valid),
      .ready_o(tx_ready),
      .tx_o   (tx_line)
  );

  // Линия приёмника: либо от uart_tx, либо от тестового передатчика.
  logic use_bfm = 1'b0;
  logic bfm_line = 1'b1;
  logic [7:0] rx_data;
  logic rx_valid;

  uart_rx #(
      .ClkFreq(ClkFreq),
      .Baud   (Baud)
  ) dut (
      .clk_i  (clk),
      .rst_i  (rst),
      .rx_i   (use_bfm ? bfm_line : tx_line),
      .data_o (rx_data),
      .valid_o(rx_valid)
  );

  // Временные диаграммы для GTKWave: uart_rx_tb.vcd.
  initial begin
    $dumpfile("uart_rx_tb.vcd");
    $dumpvars(0, uart_rx_tb);
  end

  // Все принятые байты.
  logic [7:0] received[$];

  always @(posedge clk) if (rx_valid) received.push_back(rx_data);

  // Тестовый передатчик с периодом бита bit_ns.
  task automatic bfm_send(input logic [7:0] b, input real bit_ns);
    bfm_line = 1'b0;
    #(bit_ns);
    for (int i = 0; i < 8; i++) begin
      bfm_line = b[i];
      #(bit_ns);
    end
    bfm_line = 1'b1;
    #(bit_ns);
  endtask

  int errors = 0;

  task automatic expect_received(input string what);
    if (received.size() != NumBytes) begin
      $display("FAIL: %s: received %0d bytes, expected %0d", what,
               received.size(), NumBytes);
      errors++;
    end else begin
      for (int i = 0; i < NumBytes; i++) begin
        if (received[i] !== Bytes[8*i+:8]) begin
          $display("FAIL: %s: byte %0d = %h, expected %h", what, i, received[i],
                   Bytes[8*i+:8]);
          errors++;
        end
      end
    end
    received.delete();
  endtask

  initial begin
    real bit_ns;
    bit_ns = 10.0 * ClksPerBit;
    repeat (3) @(posedge clk);
    rst <= 1'b0;

    // 1) uart_tx -> uart_rx, байты подряд.
    for (int i = 0; i < NumBytes; i++) begin
      tx_data  <= Bytes[8*i+:8];
      tx_valid <= 1'b1;
      do @(posedge clk); while (!tx_ready);
    end
    tx_valid <= 1'b0;
    repeat (12 * ClksPerBit) @(posedge clk);
    expect_received("uart_tx");

    // 2) Скорость передатчика отличается на -3% и +3%.
    use_bfm = 1'b1;
    for (int i = 0; i < NumBytes; i++) bfm_send(Bytes[8*i+:8], bit_ns * 0.97);
    repeat (2 * ClksPerBit) @(posedge clk);
    expect_received("baud -3%");
    for (int i = 0; i < NumBytes; i++) bfm_send(Bytes[8*i+:8], bit_ns * 1.03);
    repeat (2 * ClksPerBit) @(posedge clk);
    expect_received("baud +3%");

    // 3) Помеха короче половины бита: ложного байта быть не должно.
    bfm_line = 1'b0;
    #(bit_ns / 4);
    bfm_line = 1'b1;
    repeat (12 * ClksPerBit) @(posedge clk);
    if (received.size() != 0) begin
      $display("FAIL: glitch produced %0d bytes", received.size());
      errors++;
    end

    // 4) Ошибка кадра: стоп-бит равен 0 — байт отбрасывается.
    bfm_line = 1'b0;
    #(bit_ns * 10);  // старт-бит, 8 нулевых бит данных и нулевой стоп-бит
    bfm_line = 1'b1;
    repeat (12 * ClksPerBit) @(posedge clk);
    if (received.size() != 0) begin
      $display("FAIL: byte with framing error was accepted");
      errors++;
    end

    if (errors == 0) $display("PASS: all receiver checks");
    $finish;
  end

  initial begin
    #(10 * ClksPerBit * 12 * NumBytes * 6);
    $display("FAIL: timeout");
    $finish;
  end

endmodule
