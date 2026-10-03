`timescale 1ns / 1ps

// Тест button: дребезг короче StableClks не даёт нажатия; одно устойчивое нажатие даёт ровно
// один импульс press_o; отпускание импульса не даёт.
module button_tb;

  localparam int unsigned StableClks = 20;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic btn_n = 1'b1;  // кнопка с активным нулём, отпущена
  logic pressed, press;

  always #5 clk = ~clk;

  button #(
      .StableClks(StableClks),
      .ActiveLow (1'b1)
  ) dut (
      .clk_i    (clk),
      .rst_i    (rst),
      .btn_i    (btn_n),
      .pressed_o(pressed),
      .press_o  (press)
  );

  int presses = 0;
  always @(posedge clk) if (press) presses++;

  task automatic bounce();
    for (int i = 0; i < 5; i++) begin
      btn_n <= ~btn_n;
      repeat (StableClks / 4) @(posedge clk);
    end
  endtask

  int errors = 0;

  initial begin
    repeat (3) @(posedge clk);
    rst <= 1'b0;
    repeat (5) @(posedge clk);

    bounce();  // заканчивается нажатой кнопкой (нечётное число переключений)
    repeat (3 * StableClks) @(posedge clk);
    if (!pressed || presses != 1) begin
      $display("FAIL: after press: pressed=%0b, presses=%0d", pressed, presses);
      errors++;
    end

    bounce();  // отпускание с дребезгом
    repeat (3 * StableClks) @(posedge clk);
    if (pressed || presses != 1) begin
      $display("FAIL: after release: pressed=%0b, presses=%0d", pressed, presses);
      errors++;
    end

    // Импульсы короче StableClks не регистрируются.
    for (int i = 0; i < 10; i++) begin
      btn_n <= 1'b0;
      repeat (StableClks / 2) @(posedge clk);
      btn_n <= 1'b1;
      repeat (StableClks / 2) @(posedge clk);
    end
    repeat (3 * StableClks) @(posedge clk);
    if (presses != 1) begin
      $display("FAIL: short pulses produced presses: %0d", presses);
      errors++;
    end

    if (errors == 0) $display("PASS: debouncing and press pulses");
    $finish;
  end

endmodule
