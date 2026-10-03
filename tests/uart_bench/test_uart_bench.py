"""Тесты uart_bench: команды по UART, кадр с выхода цепочки совпадает с моделью."""

import os

import cocotb
import numpy as np
from cocotb.triggers import ClockCycles

from svconv_model import KERNEL_ROM_ORDER, KERNELS, pad_kernel, pipeline, sample_image
from svconv_tb import assert_frames_equal, start_clock, uart_recv, uart_send

WIDTH = int(os.environ["WIDTH"])
HEIGHT = int(os.environ["HEIGHT"])
K = int(os.environ["K"])
CLKS_PER_BIT = int(os.environ["CLK_FREQ"]) // int(os.environ["BAUD"])
SEL_W = max(1, (len(KERNEL_ROM_ORDER) - 1).bit_length())


async def setup(dut) -> None:
    start_clock(dut)
    dut.uart_rx_i.value = 1
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0


async def configure(dut, kernels: list[str], enabled: list[bool]) -> None:
    en = sum(int(e) << s for s, e in enumerate(enabled))
    sel = sum(KERNEL_ROM_ORDER.index(name) << (s * SEL_W) for s, name in enumerate(kernels))
    await uart_send(dut, dut.uart_rx_i, bytes([ord("c"), en, sel]), CLKS_PER_BIT)


async def request_frame(dut) -> np.ndarray:
    await uart_send(dut, dut.uart_rx_i, b"f", CLKS_PER_BIT)
    data = await uart_recv(dut, dut.uart_tx_o, WIDTH * HEIGHT, CLKS_PER_BIT)
    return np.frombuffer(data, dtype=np.uint8).reshape(HEIGHT, WIDTH)


def expected(kernels: list[str], enabled: list[bool]) -> np.ndarray:
    chain = [pad_kernel(KERNELS[n], K) for n, e in zip(kernels, enabled) if e]
    return pipeline(sample_image(WIDTH, HEIGHT), chain)


@cocotb.test()
async def default_config_is_identity_chain(dut):
    """После сброса все каскады включены с ядром 0 (identity)."""
    await setup(dut)
    frame = await request_frame(dut)
    assert_frames_equal(frame, expected(["identity"] * 3, [True] * 3), "default")


@cocotb.test()
async def blur_blur_edges(dut):
    await setup(dut)
    cfg = (["gauss5", "gauss5", "log5"], [True, True, True])
    await configure(dut, *cfg)
    assert_frames_equal(await request_frame(dut), expected(*cfg), "blur-blur-edges")


@cocotb.test()
async def reconfigure_between_frames(dut):
    """Перенастройка между кадрами: каждый кадр соответствует своей конфигурации."""
    await setup(dut)
    for cfg in [
        (["gauss5", "gauss5", "log5"], [False, False, True]),
        (["gauss5", "identity", "identity"], [True, False, False]),
        (["identity", "identity", "identity"], [False, False, False]),
    ]:
        await configure(dut, *cfg)
        assert_frames_equal(await request_frame(dut), expected(*cfg), f"{cfg}")


@cocotb.test()
async def frame_period(dut):
    """Источник выдаёт пиксель каждый такт, поэтому период кадра — ровно WIDTH*HEIGHT тактов."""
    await setup(dut)
    await ClockCycles(dut.clk_i, 3 * WIDTH * HEIGHT)
    await uart_send(dut, dut.uart_rx_i, b"p", CLKS_PER_BIT)
    period = int.from_bytes(await uart_recv(dut, dut.uart_tx_o, 4, CLKS_PER_BIT), "little")
    assert period == WIDTH * HEIGHT, f"period {period}, expected {WIDTH * HEIGHT}"


@cocotb.test()
async def ignores_unknown_commands(dut):
    await setup(dut)
    await uart_send(dut, dut.uart_rx_i, b"xyz", CLKS_PER_BIT)
    frame = await request_frame(dut)
    assert_frames_equal(frame, expected(["identity"] * 3, [True] * 3), "after junk")
