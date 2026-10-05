`timescale 1ns / 1ps

// Начальная настройка камеры OV7670: аппаратный сброс, затем запись таблицы регистров по SCCB.
//
// Последовательность: RESET# = 0 на 1 мс, RESET# = 1 и пауза 10 мс, программный сброс
// (COM7 = 0x80) и пауза 10 мс, затем остальные регистры таблицы. После этого done_o = 1.
// RESET# активен нулём — по даташиту OV7670 v1.4 (в версии 1.01 полярность указана наоборот).
// Пауза после сброса по даташиту — не меньше 1 мс; 10 мс взяты с запасом.
//
// Таблица регистров (режим VGA 640×480, RGB565) взята из проекта Angelo Jacobo
// https://github.com/AngeloJacobo/FPGA_OV7670_Camera_Interface (src/camera_interface.v),
// лицензия MIT, Copyright (c) 2021 Angelo Jacobo; автор, в свою очередь, ссылается на
// https://github.com/jonlwowski012/OV7670_NEXYS4_Verilog. Комментарии к записям — оригинальные.
module ov7670_init #(
    parameter int unsigned ClkFreq  = 27_000_000,  // частота clk_i, Гц
    parameter int unsigned SccbFreq = 100_000
) (
    input logic clk_i,
    input logic rst_i,  // синхронный сброс, активный уровень 1

    output logic cam_rst_n_o,  // RESET# камеры
    output logic cam_pwdn_o,  // PWDN камеры (0 — работа)
    output logic sioc_oe_o,    // SCCB, открытый сток: 1 — прижать линию к нулю
    output logic siod_oe_o,
    output logic done_o
);

  localparam int unsigned NumRegs = 78;
  localparam int unsigned Ms = ClkFreq / 1000;
  localparam int unsigned ResetClks = Ms;  // RESET# = 0
  localparam int unsigned WaitClks = 10 * Ms;  // пауза после сброса
  localparam int unsigned DelayW = $clog2(WaitClks + 1);

  // Запись таблицы: {номер регистра, значение}.
  function automatic logic [15:0] ov7670_reg(input logic [6:0] idx);
    unique case (idx)
      7'd0: ov7670_reg = 16'h12_80;  // reset all register to default values
      7'd1: ov7670_reg = 16'h12_04;  // set output format to RGB
      7'd2: ov7670_reg = 16'h15_20;  // pclk will not toggle during horizontal blank
      7'd3: ov7670_reg = 16'h40_D0;  // RGB565
      7'd4: ov7670_reg = 16'h12_04;  // COM7,     set RGB color output
      7'd5: ov7670_reg = 16'h11_80;  // CLKRC     internal PLL matches input clock
      7'd6: ov7670_reg = 16'h0C_00;  // COM3,     default settings
      7'd7: ov7670_reg = 16'h3E_00;  // COM14,    no scaling, normal pclock
      7'd8: ov7670_reg = 16'h04_00;  // COM1,     disable CCIR656
      7'd9: ov7670_reg = 16'h40_D0;  // COM15,     RGB565, full output range
      7'd10: ov7670_reg = 16'h3A_04;  // TSLB       set correct output data sequence (magic)
      7'd11: ov7670_reg = 16'h14_18;  // COM9       MAX AGC value x4 0001_1000
      7'd12: ov7670_reg = 16'h4F_B3;  // MTX1       all of these are magical matrix coefficients
      7'd13: ov7670_reg = 16'h50_B3;  // MTX2
      7'd14: ov7670_reg = 16'h51_00;  // MTX3
      7'd15: ov7670_reg = 16'h52_3D;  // MTX4
      7'd16: ov7670_reg = 16'h53_A7;  // MTX5
      7'd17: ov7670_reg = 16'h54_E4;  // MTX6
      7'd18: ov7670_reg = 16'h58_9E;  // MTXS
      7'd19: ov7670_reg = 16'h3D_C0;  // COM13 sets gamma enable, may be wrong?
      7'd20: ov7670_reg = 16'h17_14;  // HSTART     start high 8 bits
      7'd21:
      ov7670_reg = 16'h18_02;  // HSTOP      stop high 8 bits //these kill the odd colored line
      7'd22: ov7670_reg = 16'h32_80;  // HREF       edge offset
      7'd23: ov7670_reg = 16'h19_03;  // VSTART     start high 8 bits
      7'd24: ov7670_reg = 16'h1A_7B;  // VSTOP      stop high 8 bits
      7'd25: ov7670_reg = 16'h03_0A;  // VREF       vsync edge offset
      7'd26: ov7670_reg = 16'h0F_41;  // COM6       reset timings
      7'd27:
      ov7670_reg = 16'h1E_00;  // MVFP       disable mirror / flip //might have magic value of 03
      7'd28: ov7670_reg = 16'h33_0B;  // CHLF       //magic value from the internet
      7'd29: ov7670_reg = 16'h3C_78;  // COM12      no HREF when VSYNC low
      7'd30: ov7670_reg = 16'h69_00;  // GFIX       fix gain control
      7'd31: ov7670_reg = 16'h74_00;  // REG74      Digital gain control
      7'd32:
      ov7670_reg = 16'hB0_84;  // RSVD       magic value from the internet *required* for good color
      7'd33: ov7670_reg = 16'hB1_0C;  // ABLC1
      7'd34: ov7670_reg = 16'hB2_0E;  // RSVD       more magic internet values
      7'd35: ov7670_reg = 16'hB3_80;  // THL_ST
      7'd36: ov7670_reg = 16'h70_3A;
      7'd37: ov7670_reg = 16'h71_35;
      7'd38: ov7670_reg = 16'h72_11;
      7'd39: ov7670_reg = 16'h73_F0;
      7'd40: ov7670_reg = 16'hA2_02;  // gamma curve values
      7'd41: ov7670_reg = 16'h7A_20;
      7'd42: ov7670_reg = 16'h7B_10;
      7'd43: ov7670_reg = 16'h7C_1E;
      7'd44: ov7670_reg = 16'h7D_35;
      7'd45: ov7670_reg = 16'h7E_5A;
      7'd46: ov7670_reg = 16'h7F_69;
      7'd47: ov7670_reg = 16'h80_76;
      7'd48: ov7670_reg = 16'h81_80;
      7'd49: ov7670_reg = 16'h82_88;
      7'd50: ov7670_reg = 16'h83_8F;
      7'd51: ov7670_reg = 16'h84_96;
      7'd52: ov7670_reg = 16'h85_A3;
      7'd53: ov7670_reg = 16'h86_AF;
      7'd54: ov7670_reg = 16'h87_C4;
      7'd55: ov7670_reg = 16'h88_D7;
      7'd56: ov7670_reg = 16'h89_E8;  // AGC and AEC
      7'd57: ov7670_reg = 16'h13_E0;  // COM8, disable AGC / AEC
      7'd58: ov7670_reg = 16'h00_00;  // set gain reg to 0 for AGC
      7'd59: ov7670_reg = 16'h10_00;  // set ARCJ reg to 0
      7'd60: ov7670_reg = 16'h0D_40;  // magic reserved bit for COM4
      7'd61: ov7670_reg = 16'h14_18;  // COM9, 4x gain + magic bit
      7'd62: ov7670_reg = 16'hA5_05;  // BD50MAX
      7'd63: ov7670_reg = 16'hAB_07;  // DB60MAX
      7'd64: ov7670_reg = 16'h24_95;  // AGC upper limit
      7'd65: ov7670_reg = 16'h25_33;  // AGC lower limit
      7'd66: ov7670_reg = 16'h26_E3;  // AGC/AEC fast mode op region
      7'd67: ov7670_reg = 16'h9F_78;  // HAECC1
      7'd68: ov7670_reg = 16'hA0_68;  // HAECC2
      7'd69: ov7670_reg = 16'hA1_03;  // magic
      7'd70: ov7670_reg = 16'hA6_D8;  // HAECC3
      7'd71: ov7670_reg = 16'hA7_D8;  // HAECC4
      7'd72: ov7670_reg = 16'hA8_F0;  // HAECC5
      7'd73: ov7670_reg = 16'hA9_90;  // HAECC6
      7'd74: ov7670_reg = 16'hAA_94;  // HAECC7
      7'd75: ov7670_reg = 16'h13_E5;  // COM8, enable AGC / AEC
      7'd76: ov7670_reg = 16'h1E_23;  // Mirror Image
      7'd77: ov7670_reg = 16'h69_06;  // gain of RGB(manually adjusted)
      default: ov7670_reg = 16'hFF_FF;
    endcase
  endfunction

  typedef enum logic [2:0] {
    HwReset,
    HwWait,
    Write,
    WaitDone,
    SoftResetWait,
    Done
  } state_e;

  state_e state_q;
  logic [DelayW-1:0] delay_q;
  logic [6:0] idx_q;
  logic sccb_start, sccb_ready;
  logic [15:0] entry;

  assign entry = ov7670_reg(idx_q);

  sccb_writer #(
      .ClkFreq (ClkFreq),
      .SccbFreq(SccbFreq)
  ) u_sccb (
      .clk_i     (clk_i),
      .rst_i     (rst_i),
      .start_i   (sccb_start),
      .dev_addr_i(8'h42),
      .reg_addr_i(entry[15:8]),
      .data_i    (entry[7:0]),
      .ready_o   (sccb_ready),
      .sioc_oe_o (sioc_oe_o),
      .siod_oe_o (siod_oe_o)
  );

  assign sccb_start  = (state_q == Write) && sccb_ready;
  assign cam_rst_n_o = (state_q != HwReset);
  assign cam_pwdn_o  = 1'b0;
  assign done_o      = (state_q == Done);

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= HwReset;
      delay_q <= '0;
      idx_q   <= '0;
    end else begin
      unique case (state_q)
        HwReset: begin
          delay_q <= delay_q + 1'b1;
          if (delay_q == DelayW'(ResetClks - 1)) begin
            delay_q <= '0;
            state_q <= HwWait;
          end
        end
        HwWait: begin
          delay_q <= delay_q + 1'b1;
          if (delay_q == DelayW'(WaitClks - 1)) begin
            delay_q <= '0;
            state_q <= Write;
          end
        end
        // Запуск записи текущего регистра; sccb_ready падает на следующем такте.
        Write: if (sccb_ready) state_q <= WaitDone;
        WaitDone: begin
          if (sccb_ready) begin
            idx_q <= idx_q + 1'b1;
            // После программного сброса (запись 0: COM7 = 0x80) нужна пауза.
            if (idx_q == '0) state_q <= SoftResetWait;
            else if (idx_q == 7'(NumRegs - 1)) state_q <= Done;
            else state_q <= Write;
          end
        end
        SoftResetWait: begin
          delay_q <= delay_q + 1'b1;
          if (delay_q == DelayW'(WaitClks - 1)) begin
            delay_q <= '0;
            state_q <= Write;
          end
        end
        Done: ;
        default: state_q <= Done;
      endcase
    end
  end

endmodule
