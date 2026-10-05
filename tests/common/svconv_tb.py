"""Общие функции cocotb-тестов: подача потока пикселей, сбор выхода, нарезка на кадры.

Поток — valid/sof/data (см. conv2d_stage.sv): пиксель в такте с valid = 1, sof = 1 у первого
пикселя кадра, пиксели по строкам.
"""

import random

import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

# Значение неопределённого (X/Z) выходного пикселя.
UNDEFINED = -1


def start_clock(dut, period_ns: int = 10) -> None:
    import cocotb

    cocotb.start_soon(Clock(dut.clk_i, period_ns, unit="ns").start())


async def reset(dut, cycles: int = 3) -> None:
    dut.valid_i.value = 0
    dut.sof_i.value = 0
    dut.data_i.value = 0
    dut.rst_i.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk_i)
    dut.rst_i.value = 0


async def drive(dut, frames: list[np.ndarray], gap_prob: float, rng: random.Random) -> None:
    """Подаёт кадры подряд; с вероятностью gap_prob перед пикселем вставляется пауза."""
    for frame in frames:
        for idx, pixel in enumerate(frame.flatten()):
            while rng.random() < gap_prob:
                dut.valid_i.value = 0
                await RisingEdge(dut.clk_i)
            dut.valid_i.value = 1
            dut.sof_i.value = int(idx == 0)
            dut.data_i.value = int(pixel)
            await RisingEdge(dut.clk_i)
    dut.valid_i.value = 0
    dut.sof_i.value = 0


async def collect(dut, out: list[tuple[int, int]]) -> None:
    """Записывает все выходные пиксели как пары (sof, data).

    До первого sof_o на выход идут строки «предыдущего кадра», которого не было: они читаются
    из ещё не записанных буферов и в симуляции не определены (UNDEFINED). Внутри полных кадров
    таких значений быть не должно — это проверяет split_frames().
    """
    while True:
        await RisingEdge(dut.clk_i)
        if dut.valid_o.value == 1:
            data = dut.data_o.value
            out.append((int(dut.sof_o.value), int(data) if data.is_resolvable else UNDEFINED))


def split_frames(out: list[tuple[int, int]], width: int, height: int) -> list[np.ndarray]:
    """Режет выходной поток на кадры по sof; возвращает только полностью вышедшие кадры."""
    starts = [i for i, (sof, _) in enumerate(out) if sof]
    frames = []
    for s in starts:
        chunk = out[s : s + width * height]
        if len(chunk) == width * height:
            data = [d for _, d in chunk]
            assert UNDEFINED not in data, "undefined pixels inside a frame"
            frames.append(np.array(data, dtype=np.uint8).reshape(height, width))
    return frames


def assert_frames_equal(got: np.ndarray, expected: np.ndarray, label: str) -> None:
    mismatches = np.argwhere(got != expected)
    assert not len(mismatches), (
        f"{label}: {len(mismatches)} mismatches, first at (row, col) "
        f"{tuple(int(v) for v in mismatches[0])}: got {got[tuple(mismatches[0])]}, "
        f"expected {expected[tuple(mismatches[0])]}"
    )


def pack_weights(weights: np.ndarray) -> int:
    """Веса K×K -> вектор weights: вес (i, j) в битах [(i*K + j)*8 +: 8]."""
    value = 0
    for idx, w in enumerate(weights.flatten()):
        value |= (int(w) & 0xFF) << (8 * idx)
    return value


def unpack_weights(value: int, k: int) -> np.ndarray:
    """Обратное к pack_weights: вектор весов -> знаковая матрица K×K."""
    raw = [(value >> (8 * idx)) & 0xFF for idx in range(k * k)]
    return np.array([b - 256 if b > 127 else b for b in raw]).reshape(k, k)


async def uart_send(dut, line, data: bytes, clks_per_bit: int, clk=None) -> None:
    """Передаёт байты по линии line (8N1), длина бита — clks_per_bit тактов clk (по умолчанию
    dut.clk_i)."""
    clk = dut.clk_i if clk is None else clk
    for byte in data:
        for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            line.value = bit
            await ClockCycles(clk, clks_per_bit)


async def uart_recv(
    dut, line, count: int, clks_per_bit: int, timeout_bits: int = 1000, clk=None
) -> bytes:
    """Принимает count байт с линии line (8N1), выбирая биты в их серединах; clk — такт, в
    котором задана длина бита (по умолчанию dut.clk_i)."""
    clk = dut.clk_i if clk is None else clk
    out = bytearray()
    for _ in range(count):
        idle = 0
        while line.value == 1:
            await RisingEdge(clk)
            idle += 1
            assert idle < timeout_bits * clks_per_bit, f"UART: no start bit, got {len(out)} bytes"
        await ClockCycles(clk, clks_per_bit // 2)
        assert line.value == 0, "UART: start bit too short"
        byte = 0
        for i in range(8):
            await ClockCycles(clk, clks_per_bit)
            byte |= int(line.value) << i
        await ClockCycles(clk, clks_per_bit)
        assert line.value == 1, "UART: no stop bit"
        out.append(byte)
    return bytes(out)


async def dvp_camera(
    dut,
    frames: list[np.ndarray],
    h_blank: int = 20,
    v_blank: int = 50,
    vsync_len: int = 10,
    pclk=None,
) -> None:
    """Модель камеры DVP (сигналы PCLK — pclk, по умолчанию dut.pclk_i, — и dut.cam_vsync_i,
    cam_href_i, cam_data_i): для каждого кадра RGB565 — импульс VSYNC, затем строки с HREF,
    пиксель — два байта, старший первым. Данные меняются после фронта PCLK и выбираются ПЛИС
    на следующем фронте."""
    pclk = dut.pclk_i if pclk is None else pclk
    for frame in frames:
        dut.cam_vsync_i.value = 1
        await ClockCycles(pclk, vsync_len)
        dut.cam_vsync_i.value = 0
        await ClockCycles(pclk, v_blank)
        for row in frame:
            dut.cam_href_i.value = 1
            for pixel in row:
                for byte in (int(pixel) >> 8, int(pixel) & 0xFF):
                    dut.cam_data_i.value = byte
                    await RisingEdge(pclk)
            dut.cam_href_i.value = 0
            await ClockCycles(pclk, h_blank)
