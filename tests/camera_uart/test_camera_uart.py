"""Тесты camera_uart: модель камеры DVP -> стенд -> UART. Захваченный серый кадр — один из кадров
камеры (прореженный и переведённый в серый), а результат — модель цепочки, применённая именно к
нему. Размеры совпадают с параметрами в Makefile."""

import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from svconv_model import (
    KERNEL_ROM_ORDER,
    KERNELS,
    decimate,
    pad_kernel,
    pipeline,
    rgb565_to_rgb888,
    rgb888_to_gray,
)
from svconv_tb import assert_frames_equal, dvp_camera, uart_recv, uart_send

K = int(os.environ["K"])
CLKS_PER_BIT = int(os.environ["CLK_FREQ"]) // int(os.environ["BAUD"])
CAM_W, CAM_H, FACTOR = 64, 48, 4
W, H = 16, 12
SEL_W = max(1, (len(KERNEL_ROM_ORDER) - 1).bit_length())
H_BLANK, V_BLANK, VSYNC_LEN = 20, 50, 10
PCLK_NS, CLK_NS = 10, 13


async def setup(dut, num_frames: int, seed: int) -> list[np.ndarray]:
    """Запускает тактовые сигналы и камеру с num_frames разными случайными кадрами."""
    cocotb.start_soon(Clock(dut.pclk_i, PCLK_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.clk_i, CLK_NS, unit="ns").start())
    dut.uart_rx_i.value = 1
    dut.cam_vsync_i.value = 0
    dut.cam_href_i.value = 0
    dut.cam_data_i.value = 0
    dut.rst_i.value = 1
    dut.rst_pclk_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    await ClockCycles(dut.pclk_i, 3)
    dut.rst_i.value = 0
    dut.rst_pclk_i.value = 0
    rng = np.random.default_rng(seed)
    frames = [rng.integers(0, 1 << 16, (CAM_H, CAM_W), dtype=np.uint16) for _ in range(num_frames)]
    cocotb.start_soon(dvp_camera(dut, frames, H_BLANK, V_BLANK, VSYNC_LEN))
    return frames


async def configure(dut, kernels: list[str], enabled: list[bool]) -> None:
    en = sum(int(e) << s for s, e in enumerate(enabled))
    sel = sum(KERNEL_ROM_ORDER.index(n) << (s * SEL_W) for s, n in enumerate(kernels))
    await uart_send(dut, dut.uart_rx_i, bytes([ord("c"), en, sel]), CLKS_PER_BIT)


async def capture(dut) -> tuple[np.ndarray, np.ndarray]:
    await uart_send(dut, dut.uart_rx_i, b"f", CLKS_PER_BIT)
    data = await uart_recv(dut, dut.uart_tx_o, 2 * W * H, CLKS_PER_BIT, timeout_bits=5000)
    raw = np.frombuffer(data[: W * H], dtype=np.uint8).reshape(H, W)
    out = np.frombuffer(data[W * H :], dtype=np.uint8).reshape(H, W)
    return raw, out


def check(raw: np.ndarray, out: np.ndarray, frames: list[np.ndarray], kernels, enabled) -> None:
    grays = [rgb888_to_gray(rgb565_to_rgb888(decimate(f, FACTOR, W, H))) for f in frames]
    assert any((raw == g).all() for g in grays), "captured gray frame matches no camera frame"
    chain = [pad_kernel(KERNELS[n], K) for n, e in zip(kernels, enabled) if e]
    assert_frames_equal(out, pipeline(raw, chain), "processed frame")


@cocotb.test()
async def captures_frame_and_its_result(dut):
    frames = await setup(dut, num_frames=6, seed=1)
    cfg = (["gauss5", "gauss5", "log5"], [True, True, True])
    await configure(dut, *cfg)
    raw, out = await capture(dut)
    check(raw, out, frames, *cfg)


@cocotb.test()
async def reconfigure_and_capture_again(dut):
    frames = await setup(dut, num_frames=10, seed=2)
    for cfg in (
        (["identity", "identity", "identity"], [False, False, False]),
        (["gauss5", "identity", "log5"], [True, False, True]),
    ):
        await configure(dut, *cfg)
        raw, out = await capture(dut)
        check(raw, out, frames, *cfg)


@cocotb.test()
async def reports_frame_period(dut):
    """Период кадров камеры в тактах clk_i (с точностью до такта: тактовые сигналы не кратны)."""
    await setup(dut, num_frames=4, seed=3)
    await ClockCycles(dut.pclk_i, 3 * (VSYNC_LEN + V_BLANK + CAM_H * (2 * CAM_W + H_BLANK)))
    await uart_send(dut, dut.uart_rx_i, b"p", CLKS_PER_BIT)
    period = int.from_bytes(await uart_recv(dut, dut.uart_tx_o, 4, CLKS_PER_BIT), "little")
    frame_ns = PCLK_NS * (VSYNC_LEN + V_BLANK + CAM_H * (2 * CAM_W + H_BLANK))
    assert abs(period - frame_ns / CLK_NS) <= 1, f"period {period}, expected ~{frame_ns / CLK_NS}"


@cocotb.test()
async def capture_can_be_cancelled(dut):
    """Без камеры кадр не приходит; любой байт отменяет ожидание, и стенд снова принимает команды."""
    cocotb.start_soon(Clock(dut.pclk_i, PCLK_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.clk_i, CLK_NS, unit="ns").start())
    dut.uart_rx_i.value = 1
    dut.cam_vsync_i.value = 0
    dut.cam_href_i.value = 0
    dut.cam_data_i.value = 0
    dut.rst_i.value = 1
    dut.rst_pclk_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0
    dut.rst_pclk_i.value = 0
    await uart_send(dut, dut.uart_rx_i, b"f", CLKS_PER_BIT)
    await ClockCycles(dut.clk_i, 200)
    assert dut.busy_o.value == 1
    await uart_send(dut, dut.uart_rx_i, b"x", CLKS_PER_BIT)
    await ClockCycles(dut.clk_i, 20)
    assert dut.busy_o.value == 0
    await uart_send(dut, dut.uart_rx_i, b"p", CLKS_PER_BIT)
    period = int.from_bytes(await uart_recv(dut, dut.uart_tx_o, 4, CLKS_PER_BIT), "little")
    assert period == 0, "no camera frames, so the period is unknown (0)"


# Тайм-аут незавершённой команды стенда (параметр CmdTimeoutBits) с запасом.
CMD_TIMEOUT_CYCLES = 1000 * CLKS_PER_BIT + 10 * CLKS_PER_BIT


@cocotb.test()
async def truncated_command_is_discarded(dut):
    """Оборванная команда 'c' отбрасывается по тайм-ауту и не меняет цепочку; следующая
    полная команда разбирается правильно."""
    frames = await setup(dut, num_frames=16, seed=4)
    edges = (["gauss5", "gauss5", "log5"], [False, False, True])
    await configure(dut, *edges)
    await uart_send(dut, dut.uart_rx_i, bytes([ord("c"), 0]), CLKS_PER_BIT)
    await ClockCycles(dut.clk_i, CMD_TIMEOUT_CYCLES)
    raw, out = await capture(dut)
    check(raw, out, frames, *edges)
    blur = (["gauss5", "identity", "identity"], [True, False, False])
    await configure(dut, *blur)
    raw, out = await capture(dut)
    check(raw, out, frames, *blur)


@cocotb.test()
async def nonexistent_kernel_is_rejected(dut):
    """Номер ядра 3 при трёх ядрах: команда игнорируется, остаётся прежняя цепочка."""
    frames = await setup(dut, num_frames=8, seed=5)
    edges = (["gauss5", "gauss5", "log5"], [False, False, True])
    await configure(dut, *edges)
    await uart_send(dut, dut.uart_rx_i, bytes([ord("c"), 0b111, 3]), CLKS_PER_BIT)
    raw, out = await capture(dut)
    check(raw, out, frames, *edges)
