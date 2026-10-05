`timescale 1ns / 1ps

// Формальное доказательство capture_ctrl с двумя независимыми тактовыми сигналами (multiclock):
// clk_i и pclk_i — произвольные, в том числе останавливаются на любое время. Командный автомат
// заменён недетерминированной моделью (как camera_uart: ждёт кадр, может отменить ожидание,
// после done читает буферы), потоки домена PCLK — произвольные. Доказывается:
//   - пока командный автомат читает буферы (после done и до следующего ожидания), домен PCLK
//     их не пишет;
//   - done означает, что в буферы записан ровно один кадр серого и один кадр результата целиком
//     захватом, начатым в текущем ожидании — не продолжение отменённого.
// Обёртка читает внутренние регистры capture_ctrl иерархическими ссылками (read_slang).
module capture_ctrl_fv (
    input logic clk_i,
    input logic pclk_i,
    // Произвольные входы: решения модели командного автомата и потоки домена PCLK.
    input logic go,
    input logic cancel,
    input logic finish,
    input logic any_ready,
    input logic any_in_valid,
    input logic any_in_sof,
    input logic any_out_valid,
    input logic any_out_sof
);

  localparam int unsigned Pixels = 3;

  // Сброс: держится, пока каждый тактовый сигнал не даст хотя бы два фронта.
  logic [1:0] nclk_q = '0, npclk_q = '0;
  always_ff @(posedge clk_i) if (nclk_q != 2'd3) nclk_q <= nclk_q + 1'b1;
  always_ff @(posedge pclk_i) if (npclk_q != 2'd3) npclk_q <= npclk_q + 1'b1;
  logic rst;
  assign rst = (nclk_q < 2'd2) || (npclk_q < 2'd2);

  // Модель командного автомата (домен clk_i).
  localparam logic [1:0] Idle = 2'd0, Wait = 2'd1, Read = 2'd2;
  logic [1:0] st_q = Idle;
  logic done;

  always_ff @(posedge clk_i) begin
    if (rst) st_q <= Idle;
    else
      unique case (st_q)
        Idle: if (go) st_q <= Wait;
        Wait:
        if (cancel) st_q <= Idle;  // в camera_uart отмена важнее done
        else if (done) st_q <= Read;
        Read: if (finish) st_q <= Idle;
        default: st_q <= Idle;
      endcase
  end

  // Потоки домена PCLK — произвольные, меняются по фронтам pclk_i.
  logic ready_q, in_valid_q, in_sof_q, out_valid_q, out_sof_q;
  always_ff @(posedge pclk_i) begin
    ready_q     <= any_ready;
    in_valid_q  <= any_in_valid;
    in_sof_q    <= any_in_sof;
    out_valid_q <= any_out_valid;
    out_sof_q   <= any_out_sof;
  end

  logic raw_we, raw_sof, out_we, out_sof;

  capture_ctrl #(
      .Pixels(Pixels)
  ) dut (
      .clk_i      (clk_i),
      .rst_i      (rst),
      .wait_i     (st_q == Wait),
      .done_o     (done),
      .pclk_i     (pclk_i),
      .rst_pclk_i (rst),
      .ready_i    (ready_q),
      .in_valid_i (in_valid_q),
      .in_sof_i   (in_sof_q),
      .out_valid_i(out_valid_q),
      .out_sof_i  (out_sof_q),
      .raw_we_o   (raw_we),
      .raw_sof_o  (raw_sof),
      .out_we_o   (out_we),
      .out_sof_o  (out_sof)
  );

  // Номер ожидания: растёт, когда командный автомат начинает ждать кадр (после команды 'f';
  // настройка цепочки к этому времени уже применена).
  logic [7:0] nwait_q = '0;
  always_ff @(posedge clk_i) if (!rst && st_q == Idle && go) nwait_q <= nwait_q + 1'b1;

  // Наблюдатель захвата (домен PCLK): в каком ожидании начат и сколько пикселей записано.
  logic [7:0] cap_wait_q = '0;
  logic [3:0] nraw_q = '0, nout_q = '0;
  always_ff @(posedge pclk_i) begin
    if (raw_sof) begin
      cap_wait_q <= nwait_q;
      nraw_q     <= 4'd1;
      nout_q     <= '0;
    end else begin
      if (raw_we && nraw_q != 4'd15) nraw_q <= nraw_q + 1'b1;
      if (out_sof) nout_q <= 4'd1;
      else if (out_we && nout_q != 4'd15) nout_q <= nout_q + 1'b1;
    end
  end

  // Вспомогательные инварианты для индукции. Обозначения: запрос req_q проходит по кольцу
  // req_q -> синхронизатор в домен PCLK (r0, r1 = req_pclk) -> ack_q -> синхронизатор в домен
  // clk_i (a0, a1 = ack) и снова к req_q.
  logic r0, r1, a0, a1, s0, s1;
  assign {r1, r0} = dut.u_req_sync.chain_q;
  assign {a1, a0} = dut.u_ack_sync.chain_q;
  assign {s1, s0} = dut.u_served_sync.chain_q;
  logic [5:0] ring;
  assign ring = {dut.req_q, r0, r1, dut.ack_q, a0, a1};
  // Захват в домене PCLK идёт (или закончен и ждёт снятия запроса).
  logic cap_any;
  assign cap_any = dut.cap_q || dut.raw_on_q || dut.out_wait_q || dut.out_on_q || dut.served_q;

  // Кольцо и синхронизаторы верны с самого начала: у регистров, которые читает другой домен,
  // есть начальные значения. Остальные регистры домена верны, как только он получил хотя бы
  // один фронт со сбросом.
  logic pclk_init, clk_init;
  assign pclk_init = npclk_q != 0;
  assign clk_init  = nclk_q != 0;

  always_comb begin
    // Кольцо: уровень меняется только в начале кольца и бежит по нему, поэтому вдоль кольца не
    // больше одной смены значения (req_q меняется, когда значение дошло до конца).
    assert ($countones((ring ^ (ring >> 1)) & 6'b011111) <= 1);
    // Сброс бывает только при включении, когда рукопожатие ещё в покое.
    if (rst) assert (ring == '0 && !dut.served_q && !s0 && !s1);
    // served бывает, только пока домен PCLK видит запрос (ack_q — его копия).
    if (dut.served_q) assert (dut.ack_q);
    if (s0) assert (a0);
    if (s1) assert (a1);
    // Пока запрос поднят, served в синхронизаторе — только от текущего захвата: при подъёме
    // запроса синхронизатор был пуст, а served_q, раз поднявшись, не опускается, пока домен PCLK
    // не увидит снятия запроса.
    if (dut.req_q) assert ((!s0 || dut.served_q) && (!s1 || dut.served_q));
    if (pclk_init) begin
      if (cap_any) assert (dut.ack_q);
      if (dut.raw_on_q || dut.out_wait_q || dut.out_on_q) assert (dut.cap_q);
      if (dut.served_q) assert (!dut.cap_q);
      assert (!(dut.out_wait_q && dut.out_on_q));
      if (dut.raw_on_q) assert (nraw_q == 4'(dut.raw_cnt_q) && dut.raw_cnt_q < Pixels);
      if (dut.cap_q && !dut.raw_on_q) assert (nraw_q == 4'(Pixels));
      if (dut.out_wait_q) assert (nout_q == 0);
      if (dut.out_on_q) assert (nout_q == 4'(dut.out_cnt_q) && dut.out_cnt_q < Pixels);
      if (dut.cap_q && !dut.out_wait_q && !dut.out_on_q) assert (nout_q == 4'(Pixels));
      if (dut.served_q) assert (nraw_q == 4'(Pixels) && nout_q == 4'(Pixels));
    end
    if (pclk_init && clk_init) begin
      // Пока ждём и запрос текущий (want_q), захват — из текущего ожидания.
      if (st_q == Wait && dut.want_q && dut.req_q && cap_any) assert (cap_wait_q == nwait_q);
      if (dut.want_q && dut.req_q) assert (st_q != Read);
      // Пока читаем, запрос снят, а домен PCLK, если ещё видит его, уже отдал кадр.
      if (st_q == Read) assert (!dut.req_q && (!r1 || dut.served_q));
    end
  end

  always_comb begin
    if (!rst) begin
      // Пока буферы читаются, их не пишут.
      if (st_q == Read) assert (!raw_we && !out_we);
      // done — целый кадр серого и целый кадр результата от захвата, начатого в текущем
      // ожидании (а не продолженного после отмены прошлого).
      if (done) begin
        assert (st_q == Wait);
        assert (cap_wait_q == nwait_q);
        assert (nraw_q == 4'(Pixels) && nout_q == 4'(Pixels));
      end
    end
  end

endmodule
