`timescale 1ns / 1ps

// Запись регистра камеры по SCCB (совместим с I2C): старт, байт адреса устройства, байт номера
// регистра, байт значения, стоп. Девятый бит каждого байта (подтверждение камеры) не
// проверяется — в SCCB он «don't care».
//
// Обе линии работают как открытый сток: *_oe_o = 1 — прижать линию к нулю, 0 — отпустить
// (высокий уровень задают подтягивающие резисторы модуля камеры). Так ПЛИС не подаёт своё
// напряжение на линии камеры. В верхнем модуле: assign sioc = sioc_oe ? 1'b0 : 1'bz.
//
// Запись начинается по start_i при ready_o = 1 и занимает около 30 периодов SCCB.
module sccb_writer #(
    parameter int unsigned ClkFreq,  // частота clk_i, Гц
    parameter int unsigned SccbFreq = 100_000  // частота SIOC, Гц (OV7670 допускает до 400 кГц)
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1

    input logic start_i,
    input  logic [7:0] dev_addr_i,  // адрес устройства для записи (OV7670: 8'h42)
    input logic [7:0] reg_addr_i,
    input logic [7:0] data_i,
    output logic ready_o,

    output logic sioc_oe_o,
    output logic siod_oe_o
);

  // Период SCCB делится на 4 четверти; линии переключаются по концу четверти (tick). Внутри
  // бита SIOC низкий в четвертях 0-1 и высокий в 2-3; SIOD меняется на границе четвертей 0 и 1 —
  // в середине низкого уровня SIOC.
  localparam int unsigned QuarterClks = ClkFreq / (4 * SccbFreq);
  localparam int unsigned QW = (QuarterClks <= 1) ? 1 : $clog2(QuarterClks);
  localparam int unsigned NumBits = 27;  // 3 байта по 9 бит

  typedef enum logic [1:0] {
    Idle,
    Start,
    Bits,
    Stop
  } state_e;

  state_e state_q;
  logic [QW-1:0] qcnt_q;  // такты внутри четверти
  logic [1:0] quarter_q;  // номер четверти
  logic [4:0] bit_q;  // номер передаваемого бита
  // Передаваемые биты, старший первым; 1 в девятых битах — линия отпущена для ответа камеры.
  logic [NumBits-1:0] shift_q;
  logic tick;

  assign tick = (qcnt_q == QW'(QuarterClks - 1));
  assign ready_o = (state_q == Idle);

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q   <= Idle;
      qcnt_q    <= '0;
      quarter_q <= '0;
      bit_q     <= '0;
      sioc_oe_o <= 1'b0;
      siod_oe_o <= 1'b0;
    end else begin
      qcnt_q <= tick ? '0 : qcnt_q + 1'b1;
      unique case (state_q)
        Idle: begin
          qcnt_q    <= '0;
          quarter_q <= '0;
          sioc_oe_o <= 1'b0;
          siod_oe_o <= 1'b0;
          if (start_i) begin
            shift_q <= {dev_addr_i, 1'b1, reg_addr_i, 1'b1, data_i, 1'b1};
            state_q <= Start;
          end
        end
        // Старт: SIOD падает при высоком SIOC (конец четверти 1), затем SIOC опускается (конец 3).
        Start: begin
          if (tick) begin
            quarter_q <= quarter_q + 1'b1;
            if (quarter_q == 2'd1) siod_oe_o <= 1'b1;
            if (quarter_q == 2'd3) begin
              sioc_oe_o <= 1'b1;
              bit_q     <= '0;
              state_q   <= Bits;
            end
          end
        end
        Bits: begin
          if (tick) begin
            quarter_q <= quarter_q + 1'b1;
            unique case (quarter_q)
              // Конец четверти 0: выставить бит, пока SIOC низкий; конец 1: SIOC вверх — камера
              // читает бит; конец 3: SIOC вниз, переход к следующему биту.
              2'd0:    siod_oe_o <= ~shift_q[NumBits-1];
              2'd1:    sioc_oe_o <= 1'b0;
              2'd2:    ;
              2'd3: begin
                sioc_oe_o <= 1'b1;
                shift_q   <= {shift_q[NumBits-2:0], 1'b1};
                bit_q     <= bit_q + 1'b1;
                if (bit_q == 5'(NumBits - 1)) state_q <= Stop;
              end
              default: ;
            endcase
          end
        end
        // Стоп: SIOD низкий, SIOC вверх, затем SIOD вверх при высоком SIOC.
        Stop: begin
          if (tick) begin
            quarter_q <= quarter_q + 1'b1;
            unique case (quarter_q)
              2'd0: siod_oe_o <= 1'b1;
              2'd1: sioc_oe_o <= 1'b0;
              2'd2: siod_oe_o <= 1'b0;
              2'd3: state_q <= Idle;
              default: ;
            endcase
          end
        end
        default: state_q <= Idle;
      endcase
    end
  end

endmodule
