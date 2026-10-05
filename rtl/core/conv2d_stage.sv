`timescale 1ns / 1ps

// Каскад потоковой свёртки K×K для изображения Width×Height, 8 бит на пиксель.
//
// Вычисляет то же, что convolve() в model/svconv_model.py (побитово):
//   acc[r, c] = sum_{i,j} img[r + i - p, c + j - p] * w[i, j],  p = K / 2,
//   выход = насыщение(округление((abs_i ? |acc| : acc) / 2^shift_i)) до 0..255,
//   пиксели на расстоянии меньше p от края кадра равны 0.
//
// Поток: пиксель передаётся в такте с valid_i = 1, sof_i = 1 отмечает первый пиксель кадра,
// пиксели идут по строкам слева направо. Паузы (valid_i = 0) допустимы в любом месте;
// остановить источник нельзя, поэтому каскад принимает пиксель в каждом такте.
//
// Каждый входной пиксель порождает ровно один выходной. Выход отстаёт от входа на
// Lag = (p + 1) * Width + p пикселей (окно накапливается в строчных буферах) и на
// Latency тактов конвейера. Нижние p + 1 строк кадра (последняя внутренняя строка и нижняя
// рамка) выходят, пока поступает следующий кадр.
//
// Устройство (как в приложении курса «Свёртка изображений»):
//   1) K + 1 строчных буферов: в один пишется текущая строка, из остальных K читаются
//      предыдущие K строк. Запись и чтение всегда идут в разные буферы, поэтому пиксель
//      принимается каждый такт без конфликтов доступа к памяти;
//   2) окно K×K на регистрах: в каждом такте с пикселем столбцы сдвигаются влево,
//      справа добавляется столбец из K прочитанных значений;
//   3) произведения окна на веса;
//   4) одномерные свёртки — суммы произведений по каждой строке окна;
//   5) сумма по строкам;
//   6) постобработка: модуль, округление, сдвиг, насыщение, обнуление краёв.
// Признаки valid/sof/«край» проходят через сдвиговые регистры той же длины, что и данные.
module conv2d_stage #(
    parameter int unsigned Width,
    parameter int unsigned Height,
    parameter int unsigned K      = 5
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1

    // Настройка ядра. Действует сразу на вычисляемые пиксели; чтобы выходной кадр был
    // вычислен одним ядром целиком, она должна быть постоянной от начала его выхода (sof_o)
    // до конца — а нижние строки кадра выходят, когда на вход уже идёт следующий (см. выше).
    input logic [K*K*8-1:0] weights_i,  // вес (i, j), знаковый: weights_i[(i*K + j)*8 +: 8]
    input logic [3:0] shift_i,  // делитель 2^shift_i
    input logic             abs_i,      // 1 — брать модуль суммы (выделение границ)

    input logic       valid_i,
    input logic       sof_i,
    input logic [7:0] data_i,

    output logic       valid_o,
    output logic       sof_o,
    output logic [7:0] data_o
);

  localparam int unsigned P = K / 2;
  localparam int unsigned NumBufs = K + 1;
  localparam int unsigned XW = $clog2(Width);
  localparam int unsigned YW = $clog2(Height);
  localparam int unsigned BW = $clog2(NumBufs);
  // Произведение: пиксель (беззнаковый 8 бит -> знаковый 9 бит) на вес (знаковый 8 бит).
  localparam int unsigned ProdW = 17;
  localparam int unsigned AccW = ProdW + $clog2(K * K);
  // Число регистров конвейера от входа до выхода (стадии 1-6 из описания выше).
  localparam int unsigned Latency = 6;

  // ---------------------------------------------------------------------------------------
  // Вход: координаты текущего пикселя и номер буфера, в который пишется текущая строка.
  // ---------------------------------------------------------------------------------------
  logic [XW-1:0] x_q, x;
  logic [YW-1:0] y_q, y;
  logic [BW-1:0] wbuf_q;

  // sof_i принудительно начинает кадр с (0, 0), даже если счётчики сбились.
  assign x = sof_i ? '0 : x_q;
  assign y = sof_i ? '0 : y_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      x_q    <= '0;
      y_q    <= '0;
      wbuf_q <= '0;
    end else if (valid_i) begin
      if (x == XW'(Width - 1)) begin
        x_q    <= '0;
        y_q    <= (y == YW'(Height - 1)) ? '0 : y + 1'b1;
        wbuf_q <= (wbuf_q == BW'(NumBufs - 1)) ? '0 : wbuf_q + 1'b1;
      end else begin
        x_q <= x + 1'b1;
        y_q <= y;
      end
    end
  end

  // Захват кадра: пока на входе не было sof_i, позиция пикселей неизвестна (например, это
  // неопределённый поток предыдущего каскада до его первого кадра), и sof_o не выдаётся —
  // иначе потребитель принял бы этот поток за кадр.
  logic locked_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) locked_q <= 1'b0;
    else if (valid_i && sof_i) locked_q <= 1'b1;
  end

  // Центр окна, которое будет готово после этого пикселя: (y - 1 - p, x - p).
  // Если x < p, центр лежит в конце предыдущей строки. Если строка центра отрицательна,
  // это одна из нижних p + 1 строк предыдущего кадра: её окно ещё лежит в буферах, поэтому
  // номер строки переводится в нумерацию предыдущего кадра (+Height). Среди этих строк
  // последняя внутренняя строка кадра (Height - 1 - p), остальные — нижняя рамка.
  int cx, cy;
  logic border, out_sof;

  always_comb begin
    cx = int'(x) - int'(P);
    cy = int'(y) - 1 - int'(P);
    if (cx < 0) begin
      cx = cx + int'(Width);
      cy = cy - 1;
    end
    if (cy < 0) cy = cy + int'(Height);
    border = (cy < int'(P)) || (cy > int'(Height) - 1 - int'(P)) ||
             (cx < int'(P)) || (cx > int'(Width) - 1 - int'(P));
    out_sof = (cx == 0) && (cy == 0);
  end

  // ---------------------------------------------------------------------------------------
  // 1) Строчные буферы. Все буферы читаются по адресу x; на следующем такте выбираем K
  //    буферов, не занятых записью, от самой старой строки к самой новой.
  // ---------------------------------------------------------------------------------------
  logic [7:0] rdata[NumBufs];

  for (genvar b = 0; b < NumBufs; b++) begin : g_line_buf
    sdp_ram #(
        .Depth(Width),
        .DataW(8)
    ) u_ram (
        .clk_i  (clk_i),
        .we_i   (valid_i && (wbuf_q == BW'(b))),
        .waddr_i(x),
        .wdata_i(data_i),
        .raddr_i(x),
        .rdata_o(rdata[b])
    );
  end

  logic          s1_valid_q;
  logic [BW-1:0] s1_wbuf_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) s1_valid_q <= 1'b0;
    else s1_valid_q <= valid_i;
    s1_wbuf_q <= wbuf_q;
  end

  // Строка i окна (0 — самая старая): буфер wbuf + 1 + i по кругу.
  logic [7:0] col[K];

  always_comb begin
    for (int i = 0; i < K; i++) begin
      col[i] = rdata[(int'(s1_wbuf_q)+1+i)%NumBufs];
    end
  end

  // ---------------------------------------------------------------------------------------
  // 2) Окно K×K: win_q[i][j], j = K-1 — самый новый столбец.
  // ---------------------------------------------------------------------------------------
  logic [7:0] win_q[K][K];

  always_ff @(posedge clk_i) begin
    if (s1_valid_q) begin
      for (int i = 0; i < K; i++) begin
        for (int j = 0; j < K - 1; j++) win_q[i][j] <= win_q[i][j+1];
        win_q[i][K-1] <= col[i];
      end
    end
  end

  // ---------------------------------------------------------------------------------------
  // 3) Произведения, 4) суммы по строкам окна, 5) общая сумма.
  // ---------------------------------------------------------------------------------------
  logic signed [ProdW-1:0] prod_q[K][K];
  logic signed [AccW-1:0] row_sum_q[K];
  logic signed [AccW-1:0] sum_q;

  always_ff @(posedge clk_i) begin
    for (int i = 0; i < K; i++) begin
      for (int j = 0; j < K; j++) begin
        prod_q[i][j] <= $signed({1'b0, win_q[i][j]}) * $signed(weights_i[(i*K+j)*8+:8]);
      end
    end
  end

  logic signed [AccW-1:0] row_sum[K];

  always_comb begin
    for (int i = 0; i < K; i++) begin
      row_sum[i] = '0;
      for (int j = 0; j < K; j++) row_sum[i] = row_sum[i] + AccW'(prod_q[i][j]);
    end
  end

  always_ff @(posedge clk_i) begin
    for (int i = 0; i < K; i++) row_sum_q[i] <= row_sum[i];
  end

  logic signed [AccW-1:0] sum;

  always_comb begin
    sum = '0;
    for (int i = 0; i < K; i++) sum = sum + row_sum_q[i];
  end

  always_ff @(posedge clk_i) sum_q <= sum;

  // ---------------------------------------------------------------------------------------
  // 6) Постобработка: модуль, округление половины вверх, сдвиг, насыщение до 0..255.
  // ---------------------------------------------------------------------------------------
  logic [7:0] pixel;

  conv_postprocess #(
      .AccW(AccW)
  ) u_post (
      .sum_i  (sum_q),
      .shift_i(shift_i),
      .abs_i  (abs_i),
      .pixel_o(pixel)
  );

  // ---------------------------------------------------------------------------------------
  // Признаки, сопровождающие пиксель по конвейеру: valid, sof и «край» — сдвиговые регистры.
  // Бит n соответствует стадии n + 1; бит Latency - 2 сопровождает sum_q.
  // ---------------------------------------------------------------------------------------
  logic [Latency-1:0] valid_sr_q, sof_sr_q, border_sr_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      valid_sr_q <= '0;
      sof_sr_q   <= '0;
    end else begin
      valid_sr_q <= {valid_sr_q[Latency-2:0], valid_i};
      sof_sr_q   <= {sof_sr_q[Latency-2:0], valid_i && out_sof && (locked_q || sof_i)};
    end
    border_sr_q <= {border_sr_q[Latency-2:0], border};
  end

  always_ff @(posedge clk_i) begin
    data_o <= border_sr_q[Latency-2] ? 8'd0 : pixel;
  end

  assign valid_o = valid_sr_q[Latency-1];
  assign sof_o   = sof_sr_q[Latency-1];

endmodule
