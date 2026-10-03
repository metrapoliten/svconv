`timescale 1ns / 1ps

// Формальная проверка sccb_writer: при любых запросах на линиях — корректная транзакция SCCB.
// Наблюдатель смотрит только на уровни линий (открытый сток: уровень = не oe) и проверяет:
//   - в покое (ready_o) обе линии отпущены;
//   - внутри транзакции SIOD меняется только при низком SIOC, кроме старта и стопа;
//   - между стартом и стопом ровно 27 фронтов SIOC с данными, и это
//     {адрес, 1, регистр, 1, значение, 1} — то, что было запрошено.
module sccb_writer_fv (
    input logic       clk_i,
    input logic       rst_i,
    input logic       start_i,
    input logic [7:0] dev_addr_i,
    input logic [7:0] reg_addr_i,
    input logic [7:0] data_i
);

  logic ready, sioc_oe, siod_oe;

  // Четверть периода SCCB — один такт.
  sccb_writer #(
      .ClkFreq (400),
      .SccbFreq(100)
  ) dut (
      .clk_i     (clk_i),
      .rst_i     (rst_i),
      .start_i   (start_i),
      .dev_addr_i(dev_addr_i),
      .reg_addr_i(reg_addr_i),
      .data_i    (data_i),
      .ready_o   (ready),
      .sioc_oe_o (sioc_oe),
      .siod_oe_o (siod_oe)
  );

  logic init_q = 1'b1;
  always_ff @(posedge clk_i) init_q <= 1'b0;
  always_comb assume (rst_i == init_q);

  logic scl, sda;
  assign scl = !sioc_oe;
  assign sda = !siod_oe;

  logic scl_q = 1'b1, sda_q = 1'b1;
  logic in_tx_q = 1'b0;  // между стартом и стопом
  logic [4:0] nbits_q = '0;
  logic [26:0] bits_q = '0;
  logic [26:0] expected_q = '0;
  logic start_cond, stop_cond, scl_rise;

  assign start_cond = scl_q && scl && sda_q && !sda;
  assign stop_cond  = scl_q && scl && !sda_q && sda;
  assign scl_rise   = !scl_q && scl;

  always_ff @(posedge clk_i) begin
    if (!init_q) begin
      scl_q <= scl;
      sda_q <= sda;
      if (start_i && ready) expected_q <= {dev_addr_i, 1'b1, reg_addr_i, 1'b1, data_i, 1'b1};
      if (start_cond) begin
        in_tx_q <= 1'b1;
        nbits_q <= '0;
      end else if (stop_cond) begin
        in_tx_q <= 1'b0;
      end else if (in_tx_q && scl_rise && nbits_q != 5'd27) begin
        // После 27 бит фронт SIOC — часть стопа.
        bits_q  <= {bits_q[25:0], sda};
        nbits_q <= nbits_q + 1'b1;
      end
    end
  end

  always_comb begin
    if (!init_q) begin
      if (ready) assert (scl && sda);
      // Вспомогательный инвариант для индукции: в покое транзакция завершена.
      if (ready) assert (!in_tx_q);
      // При высоком SIOC уровень SIOD меняется только стартом (вне транзакции) или стопом
      // (после всех 27 бит).
      if (scl_q && scl && sda_q != sda) begin
        assert (start_cond ? !in_tx_q : (in_tx_q && nbits_q == 5'd27));
      end
      if (stop_cond) assert (bits_q == expected_q);
      assert (nbits_q <= 5'd27);
    end
  end

endmodule
