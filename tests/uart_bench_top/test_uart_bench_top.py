"""Сквозной тест uart_bench_top — того, что загружается в Primer 20K: верхний модуль со сбросом
после включения, рабочими размерами 160×120 и цепочкой по умолчанию. Компьютер ничего не
настраивает: первый же кадр должен совпасть с моделью для цепочки gauss5 -> gauss5 -> log5."""

import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from svconv_model import KERNELS, pipeline, sample_image
from svconv_tb import assert_frames_equal, uart_recv, uart_send

WIDTH, HEIGHT = 160, 120
CLKS_PER_BIT = int(os.environ["CLK_FREQ"]) // int(os.environ["BAUD"])
DEFAULT_CHAIN = ["gauss5", "gauss5", "log5"]  # DefaultSel в uart_bench_top


@cocotb.test()
async def first_frame_after_power_up(dut):
    cocotb.start_soon(Clock(dut.clk27_i, 37, unit="ns").start())
    dut.uart_rx_i.value = 1
    # Сброса снаружи нет: сброс после включения — счётчик por_cnt_q внутри модуля.
    await ClockCycles(dut.clk27_i, 200)
    # LED3 (led_n_o[1], активный 0) — ядра загружены.
    assert int(dut.led_n_o.value) & 0b0010 == 0, "kernels are not loaded after power-up"
    assert int(dut.led_n_o.value) & 0b0100 != 0, "LED4 (busy) is on while idle"

    await uart_send(dut, dut.uart_rx_i, b"f", CLKS_PER_BIT, clk=dut.clk27_i)
    # Первый байт — после пропуска одного кадра и захвата следующего (~3 кадра).
    data = await uart_recv(
        dut, dut.uart_tx_o, WIDTH * HEIGHT, CLKS_PER_BIT, timeout_bits=10_000, clk=dut.clk27_i
    )
    frame = np.frombuffer(data, dtype=np.uint8).reshape(HEIGHT, WIDTH)
    expected = pipeline(sample_image(WIDTH, HEIGHT), [KERNELS[n] for n in DEFAULT_CHAIN])
    assert_frames_equal(frame, expected, "first frame, default chain")

    await uart_send(dut, dut.uart_rx_i, b"p", CLKS_PER_BIT, clk=dut.clk27_i)
    period = int.from_bytes(
        await uart_recv(dut, dut.uart_tx_o, 4, CLKS_PER_BIT, clk=dut.clk27_i), "little"
    )
    assert period == WIDTH * HEIGHT, f"frame period {period}, expected {WIDTH * HEIGHT}"
