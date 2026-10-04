`timescale 1ns / 1ps

// Передача одиночных импульсов (длиной в такт) из домена src в домен dst. Короткий импульс
// нельзя пропустить через level_sync напрямую: более медленный приёмник может его не увидеть.
// Поэтому в домене src каждый импульс переключает триггер (toggle), уровень этого триггера
// переходит в домен dst через level_sync, а импульс восстанавливается по смене уровня.
//
// Импульсы должны идти не чаще, чем раз в несколько тактов dst, иначе два переключения
// сольются. Сброс не нужен: значение имеет только смена уровня, а не сам уровень.
module pulse_sync (
    input  logic src_clk_i,
    input  logic src_pulse_i,
    input  logic dst_clk_i,
    output logic dst_pulse_o
);

  logic toggle_q = 1'b0;
  logic toggle_dst;
  logic toggle_dst_q = 1'b0;

  always_ff @(posedge src_clk_i) if (src_pulse_i) toggle_q <= ~toggle_q;

  level_sync u_sync (
      .clk_i(dst_clk_i),
      .d_i  (toggle_q),
      .q_o  (toggle_dst)
  );

  always_ff @(posedge dst_clk_i) toggle_dst_q <= toggle_dst;

  assign dst_pulse_o = toggle_dst ^ toggle_dst_q;

endmodule
