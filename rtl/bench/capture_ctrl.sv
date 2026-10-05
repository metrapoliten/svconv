`timescale 1ns / 1ps

// Управление захватом кадра для camera_uart: запрос — в домене clk_i (команды), захват — в
// домене PCLK (камера). Захватывается один серый кадр (вход цепочки свёрток) целиком, с его sof,
// и результат цепочки для него — первый кадр на выходе цепочки, начавшийся после начала серого
// (цепочка отстаёт меньше чем на кадр; лишних sof на её выходе в это время быть не должно — за
// это отвечает ready_i). Буферы пишет домен PCLK, читает домен clk_i.
//
// Запрос передаётся четырёхфазным рукопожатием уровнями, а не импульсами, потому что PCLK может
// стоять (камера не работает), а остановленный домен пропускает импульсы. req_q = 1 — нужен
// кадр; домен PCLK отвечает уровнями ack (видит запрос) и served (кадр захвачен).
//   1. req_q поднимается, только когда ack = 0 (и served = 0): домен PCLK увидел снятие
//      прошлого запроса и прервал его захват;
//   2. домен PCLK, увидев запрос, поднимает ack и захватывает кадр, затем поднимает served;
//   3. req_q снимается, только когда ack = 1 — домен PCLK точно увидел этот запрос, — и кадр
//      захвачен или больше не нужен (ожидание отменили: wait_i опустился хотя бы раз);
//   4. домен PCLK, увидев снятие, прерывает незаконченный захват и опускает ack и served.
// Каждый уровень меняется, только когда другая сторона увидела его прошлое значение, поэтому
// никакая последовательность отмен и запросов, даже при остановленном PCLK, не продолжит старый
// захват под новым запросом. Пока запрос не поднят снова, домен PCLK буферы не пишет: их можно
// читать.
module capture_ctrl #(
    parameter int unsigned Pixels = 160 * 120  // пикселей в кадре
) (
    // Домен clk_i.
    input logic clk_i,
    input logic rst_i,  // синхронный сброс домена clk_i
    input  logic wait_i,  // командный автомат ждёт кадр; 0 — кадр не нужен (в том числе отмена)
    output logic done_o,  // кадр захвачен целиком; буферы не пишутся, пока wait_i не станет 0
                          // и снова 1

    // Домен PCLK.
    input logic pclk_i,
    input logic rst_pclk_i,  // синхронный сброс домена PCLK
    input logic ready_i,  // выход цепочки надёжен: ядра загружены и конфигурация не менялась
    input logic in_valid_i,  // серый кадр (вход цепочки)
    input logic in_sof_i,
    input logic out_valid_i,  // результат цепочки
    input logic out_sof_i,
    output logic raw_we_o,     // запись серого кадра в буфер; raw_sof_o — его первый пиксель
    output logic raw_sof_o,
    output logic out_we_o,     // запись результата в буфер; out_sof_o — его первый пиксель
    output logic out_sof_o
);

  localparam int unsigned AddrW = (Pixels > 1) ? $clog2(Pixels) : 1;

  // ---------------------------------------------------------------------------------------
  // Домен clk_i: запрос.
  // ---------------------------------------------------------------------------------------
  // Уровни, которые читает другой домен, получают начальные значения при загрузке ПЛИС: сброс
  // синхронный, и до первого фронта своего такта другой домен уже видит их.
  logic req_q = 1'b0;
  logic want_q;  // запрос ещё нужен: ожидание не отменяли с момента его подъёма
  // Уровни домена PCLK, пересчитанные в домен clk_i.
  logic ack, served;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      req_q  <= 1'b0;
      want_q <= 1'b0;
    end else if (!req_q) begin
      if (wait_i && !ack && !served) begin
        req_q  <= 1'b1;
        want_q <= 1'b1;
      end
    end else begin
      if (!wait_i) want_q <= 1'b0;
      if (ack && (served || !wait_i || !want_q)) req_q <= 1'b0;
    end
  end

  assign done_o = wait_i && want_q && req_q && ack && served;

  // ---------------------------------------------------------------------------------------
  // Домен PCLK: захват.
  // ---------------------------------------------------------------------------------------
  logic req_pclk;

  level_sync u_req_sync (
      .clk_i(pclk_i),
      .d_i  (req_q),
      .q_o  (req_pclk)
  );

  logic cap_q;  // захват идёт: начат и ещё не закончен
  logic raw_on_q, out_wait_q, out_on_q;
  logic ack_q = 1'b0, served_q = 1'b0;
  logic [AddrW-1:0] raw_cnt_q, out_cnt_q;
  logic raw_start, out_start;

  assign raw_start = req_pclk && !served_q && !cap_q && ready_i && in_valid_i && in_sof_i;
  assign out_start = out_wait_q && out_valid_i && out_sof_i;

  always_ff @(posedge pclk_i) begin
    if (rst_pclk_i) begin
      cap_q      <= 1'b0;
      raw_on_q   <= 1'b0;
      out_wait_q <= 1'b0;
      out_on_q   <= 1'b0;
      ack_q      <= 1'b0;
      served_q   <= 1'b0;
      raw_cnt_q  <= '0;
      out_cnt_q  <= '0;
    end else begin
      ack_q <= req_pclk;

      if (raw_start) begin
        cap_q      <= 1'b1;
        raw_on_q   <= (Pixels > 1);
        out_wait_q <= 1'b1;
        raw_cnt_q  <= AddrW'(1);
      end else if (raw_on_q && in_valid_i) begin
        if (raw_cnt_q == AddrW'(Pixels - 1)) raw_on_q <= 1'b0;
        raw_cnt_q <= raw_cnt_q + 1'b1;
      end

      if (out_start) begin
        out_wait_q <= 1'b0;
        out_on_q   <= (Pixels > 1);
        out_cnt_q  <= AddrW'(1);
      end else if (out_on_q && out_valid_i) begin
        if (out_cnt_q == AddrW'(Pixels - 1)) out_on_q <= 1'b0;
        out_cnt_q <= out_cnt_q + 1'b1;
      end

      // Кадр захвачен, когда записаны оба: и серый кадр, и результат.
      if (cap_q && !raw_on_q && !out_wait_q && !out_on_q) begin
        cap_q    <= 1'b0;
        served_q <= 1'b1;
      end

      // Запрос снят: захват прерывается (отмена), served снимается (конец рукопожатия) — в том
      // же такте, что и ack_q, поэтому ack = 0 в домене clk_i значит, что старого захвата нет.
      if (!req_pclk) begin
        cap_q      <= 1'b0;
        raw_on_q   <= 1'b0;
        out_wait_q <= 1'b0;
        out_on_q   <= 1'b0;
        served_q   <= 1'b0;
      end
    end
  end

  assign raw_we_o  = in_valid_i && (raw_start || raw_on_q);
  assign raw_sof_o = raw_start;
  assign out_we_o  = out_valid_i && (out_start || out_on_q);
  assign out_sof_o = out_start;

  level_sync u_ack_sync (
      .clk_i(clk_i),
      .d_i  (ack_q),
      .q_o  (ack)
  );

  level_sync u_served_sync (
      .clk_i(clk_i),
      .d_i  (served_q),
      .q_o  (served)
  );

endmodule
