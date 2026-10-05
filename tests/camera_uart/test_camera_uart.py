"""Тесты camera_uart: модель камеры DVP -> стенд -> UART. Захваченный серый кадр — один из кадров
камеры (прореженный и переведённый в серый), а результат — модель цепочки, применённая именно к
нему. Размеры совпадают с параметрами в Makefile."""

import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from svconv_model import (
    KERNEL_ROM_ORDER,
    KERNELS,
    decimate,
    pad_kernel,
    pipeline,
    rgb565_to_rgb888,
    rgb888_to_gray,
)
from svconv_tb import assert_frames_equal, dvp_camera, uart_recv, uart_send, wait_start_bit

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
    """Без камеры кадр не приходит; любой байт отменяет ожидание, и стенд снова принимает
    команды."""
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


@cocotb.test()
async def request_survives_stopped_pclk(dut):
    """PCLK стоит (камера не работает): запрос, отмена и новый запрос. Когда камера заработает,
    стенд отвечает на последний запрос кадром — запрос передаётся состоянием, а не событиями,
    которые остановленный домен мог бы потерять."""
    cocotb.start_soon(Clock(dut.clk_i, CLK_NS, unit="ns").start())
    dut.uart_rx_i.value = 1
    dut.cam_vsync_i.value = 0
    dut.cam_href_i.value = 0
    dut.cam_data_i.value = 0
    dut.rst_i.value = 1
    dut.rst_pclk_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0
    for cmd in (b"f", b"x", b"f"):
        await uart_send(dut, dut.uart_rx_i, cmd, CLKS_PER_BIT)
        await ClockCycles(dut.clk_i, 20)
    assert dut.busy_o.value == 1, "the second request is not waiting for a frame"
    # Камера заработала.
    cocotb.start_soon(Clock(dut.pclk_i, PCLK_NS, unit="ns").start())
    await ClockCycles(dut.pclk_i, 3)
    dut.rst_pclk_i.value = 0
    rng = np.random.default_rng(8)
    frames = [rng.integers(0, 1 << 16, (CAM_H, CAM_W), dtype=np.uint16) for _ in range(4)]
    cocotb.start_soon(dvp_camera(dut, frames, H_BLANK, V_BLANK, VSYNC_LEN))
    data = await uart_recv(dut, dut.uart_tx_o, 2 * W * H, CLKS_PER_BIT, timeout_bits=5000)
    raw = np.frombuffer(data[: W * H], dtype=np.uint8).reshape(H, W)
    out = np.frombuffer(data[W * H :], dtype=np.uint8).reshape(H, W)
    check(raw, out, frames, ["identity"] * 3, [True] * 3)


@cocotb.test()
async def cancel_of_started_capture_survives_stopped_pclk(dut):
    """Захват уже начался, и PCLK остановился посреди кадра (камера отключилась). Отмена, новая
    настройка и новый запрос, затем PCLK возобновляется: старый захват должен прерваться, а
    ответ — быть целым кадром, посчитанным новой цепочкой."""
    pclk = Clock(dut.pclk_i, PCLK_NS, unit="ns")
    pclk.start()
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
    rng = np.random.default_rng(9)
    frames = [rng.integers(0, 1 << 16, (CAM_H, CAM_W), dtype=np.uint16) for _ in range(8)]
    cocotb.start_soon(dvp_camera(dut, frames, H_BLANK, V_BLANK, VSYNC_LEN))
    # Цепочка по умолчанию; запрос кадра, захват начинается.
    await uart_send(dut, dut.uart_rx_i, b"f", CLKS_PER_BIT)
    while dut.raw_on_q.value != 1:
        await RisingEdge(dut.pclk_i)
    await ClockCycles(dut.pclk_i, 8 * (2 * CAM_W + H_BLANK))
    pclk.stop()
    await uart_send(dut, dut.uart_rx_i, b"x", CLKS_PER_BIT)
    edges = (["gauss5", "gauss5", "log5"], [False, False, True])
    await configure(dut, *edges)
    await uart_send(dut, dut.uart_rx_i, b"f", CLKS_PER_BIT)
    await ClockCycles(dut.clk_i, 50)
    pclk.start()
    data = await uart_recv(dut, dut.uart_tx_o, 2 * W * H, CLKS_PER_BIT, timeout_bits=5000)
    raw = np.frombuffer(data[: W * H], dtype=np.uint8).reshape(H, W)
    out = np.frombuffer(data[W * H :], dtype=np.uint8).reshape(H, W)
    check(raw, out, frames, *edges)


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


@cocotb.test()
async def command_during_last_reply_byte_is_ignored(dut):
    """Пока передаётся последний байт ответа, стенд занят (busy_o = 1) и новую команду
    игнорирует; после ответа снова принимает команды."""
    await setup(dut, num_frames=2, seed=6)
    await uart_send(dut, dut.uart_rx_i, b"p", CLKS_PER_BIT)
    await uart_recv(dut, dut.uart_tx_o, 2, CLKS_PER_BIT)
    # Команда, начатая со старт-битом третьего байта ответа, принимается (по её стоп-биту) в
    # начале четвёртого, последнего: в этот момент автомат уже в Idle, но передатчик занят.
    # Третий байт идёт сразу за вторым: старт-бит — примерно через полбита после выборки стоп-бита.
    await wait_start_bit(dut, dut.uart_tx_o, CLKS_PER_BIT, 2, what=" of the third reply byte")
    cocotb.start_soon(uart_send(dut, dut.uart_rx_i, b"p", CLKS_PER_BIT))
    await uart_recv(dut, dut.uart_tx_o, 1, CLKS_PER_BIT)
    assert dut.busy_o.value == 1, "busy_o is 0 while the last reply byte is being sent"
    await uart_recv(dut, dut.uart_tx_o, 1, CLKS_PER_BIT)
    for _ in range(40 * CLKS_PER_BIT):
        await RisingEdge(dut.clk_i)
        assert dut.uart_tx_o.value == 1, "a command received during the last reply byte was run"
    await uart_send(dut, dut.uart_rx_i, b"p", CLKS_PER_BIT)
    await uart_recv(dut, dut.uart_tx_o, 4, CLKS_PER_BIT)
