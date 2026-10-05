`timescale 1ns / 1ps

// Синхронизатор уровня: сигнал из другого тактового домена (или асинхронный вход платы)
// проходит через Stages триггеров подряд. Первый триггер может попасть в метастабильное
// состояние; следующие дают ему целый такт на то, чтобы установиться в 0 или 1. Выход
// отстаёт от входа на Stages тактов clk_i.
//
// Для многоразрядного сигнала годится, только если он меняется редко и допустимо, что в такт
// смены разряды придут из разных значений (так передаются настройки). Одиночные импульсы так
// передавать нельзя — их может «не заметить» более медленный домен.
module level_sync #(
    parameter int unsigned Width = 1,
    parameter int unsigned Stages = 2,
    parameter logic [Width-1:0] Init = '0  // значение после загрузки ПЛИС
) (
    input  logic             clk_i,
    input  logic [Width-1:0] d_i,
    output logic [Width-1:0] q_o
);

  if (Stages < 2) begin : g_check_stages
    $error("level_sync: at least two stages are needed against metastability");
  end

  // Цепочка триггеров, младшие Width бит — первый триггер.
  logic [Stages*Width-1:0] chain_q = {Stages{Init}};

  always_ff @(posedge clk_i) chain_q <= {chain_q[(Stages-1)*Width-1:0], d_i};

  assign q_o = chain_q[Stages*Width-1-:Width];

endmodule
