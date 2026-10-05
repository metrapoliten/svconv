`timescale 1ns / 1ps

// Формальное доказательство (k-индукция) uart_rx в паре с uart_tx: для любой
// последовательности байт и пауз приёмник выдаёт каждый переданный байт ровно один раз, без искажений и не позднее чем
// через кадр после начала передачи, и не выдаёт ничего лишнего.
//
// Индукции нужны инварианты о внутреннем состоянии передатчика и приёмника, поэтому обёртка
// читает их регистры иерархическими ссылками (u_tx.shift_q, dut.state_q и т. п.); их понимает
// фронтенд read_slang, а не read_verilog (см. uart_rx.sby).
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

  // Расписание кадра в тактах от его приёма передатчиком (возраст age_q).
  // Передатчик выдаёт на линию бит i на возрастах i*ClksPerBit+1 .. (i+1)*ClksPerBit
  // и освобождается на возрасте TxDone.
  localparam int unsigned TxDone = 10 * ClksPerBit;
  // Старт-бит появляется на линии на возрасте 1, проходит два триггера синхронизатора, и на
  // возрасте 3 приёмник видит спад — с возраста 4 он в состоянии Start.
  localparam int unsigned AgeStart = 4;
  // В Start приёмник ждёт полбита (до счёта (ClksPerBit-1)/2 включительно).
  localparam int unsigned AgeData = AgeStart + (ClksPerBit - 1) / 2 + 1;
  // Восемь бит данных по ClksPerBit тактов, затем стоп-бит.
  localparam int unsigned AgeStop = AgeData + 8 * ClksPerBit;
  // Байт выдаётся (valid_o) в такт, когда передатчик освобождается.
  localparam int unsigned AgeDone = AgeStop + ClksPerBit;
  if (AgeDone != TxDone) begin : g_check_schedule
    $error("uart_rx_fv: the invariants assume that rx finishes when tx does");
  end

  // Коды состояний uart_rx (порядок state_e; на константы перечисления иерархической ссылкой
  // сослаться нельзя).
  localparam logic [1:0] RxIdle = 2'd0, RxStart = 2'd1, RxData = 2'd2, RxStop = 2'd3;

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
        age_q     <= '0;
      end else if (pending_q) begin
        age_q <= age_q + 1'b1;
      end
    end
  end

  logic [9:0] frame;  // {стоп, данные, старт}
  assign frame = {1'b1, sent_q, 1'b0};

  // Значение линии на возрасте a (до кадра и после него — покой, 1).
  function automatic logic line_at(input logic [9:0] f, input int a);
    if (a < 1 || a > int'(TxDone)) return 1'b1;
    return f[(a-1)/ClksPerBit];
  endfunction

  // Ещё не переданные биты кадра: передатчик сдвигает их вправо и дополняет единицами.
  logic [19:0] tx_rest;
  assign tx_rest = {10'h3ff, frame} >> (age_q / ClksPerBit);

  // Принято бит данных и биты sent_q, которые уже должны быть в старших разрядах shift_q.
  int unsigned rx_bits;
  assign rx_bits = (int'(age_q) - AgeData) / ClksPerBit;

  always_comb begin
    if (init_q == 2'd3) begin
      // Байт выдаётся только если он был отправлен, и ровно тот, что отправлен.
      if (rx_valid) assert (pending_q && rx_data == sent_q);
      // Следующий байт уходит только после того, как предыдущий принят.
      if (valid_i && tx_ready) assert (!pending_q || rx_valid);
      // Байт принимается не позднее MaxLatency тактов.
      if (pending_q) assert (age_q <= 8'(MaxLatency));

      // Вспомогательные инварианты для индукции: они отсекают недостижимые состояния, в которых
      // наблюдатель, передатчик и приёмник рассогласованы. Состояние всех трёх задаётся age_q.
      if (!pending_q) begin
        // Покой: передатчик свободен, линия и синхронизатор в 1, приёмник ждёт старт-бит.
        assert (tx_ready && line && dut.u_sync.chain_q == 2'b11);
        assert (dut.state_q == RxIdle);
      end else begin
        assert (age_q <= 8'(AgeDone));
        // Передатчик: на линии текущий бит, счётчики и сдвиговый регистр соответствуют возрасту.
        assert (line == line_at(frame, int'(age_q)));
        if (age_q < 8'(TxDone)) begin
          assert (!tx_ready);
          assert (u_tx.bits_left_q == 4'(10 - age_q / ClksPerBit));
          assert (u_tx.clk_cnt_q == 3'(age_q % ClksPerBit));
          assert (u_tx.shift_q == tx_rest[9:0]);
        end else begin
          assert (tx_ready);
        end
        // Синхронизатор хранит значения линии за два предыдущих такта.
        assert (dut.u_sync.chain_q[0] == line_at(frame, int'(age_q) - 1));
        assert (dut.u_sync.chain_q[1] == line_at(frame, int'(age_q) - 2));
        // Приёмник.
        assert (rx_valid == (age_q == 8'(AgeDone)));
        if (age_q < 8'(AgeStart)) begin
          assert (dut.state_q == RxIdle);
        end else if (age_q < 8'(AgeData)) begin
          assert (dut.state_q == RxStart);
          assert (dut.clk_cnt_q == 3'(age_q - AgeStart));
        end else if (age_q < 8'(AgeStop)) begin
          assert (dut.state_q == RxData);
          assert (dut.clk_cnt_q == 3'((age_q - AgeData) % ClksPerBit));
          assert (dut.bit_idx_q == 3'(rx_bits));
          // Уже принятые биты лежат в старших разрядах shift_q.
          assert ((dut.shift_q >> (8 - rx_bits)) == (sent_q & ~(8'hff << rx_bits)));
        end else if (age_q < 8'(AgeDone)) begin
          assert (dut.state_q == RxStop);
          assert (dut.clk_cnt_q == 3'(age_q - AgeStop));
          assert (dut.shift_q == sent_q);
        end else begin
          assert (dut.state_q == RxIdle);
          assert (dut.shift_q == sent_q);
        end
      end
    end else if (init_q != 2'd0) begin
      // Во время сброса линия в покое (иначе индукция начинала бы со сброса при линии в 0
      // и неизвестном содержимом синхронизатора).
      assert (line);
    end
  end

endmodule
