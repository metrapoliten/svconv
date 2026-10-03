"""Общие функции cocotb-тестов: подача потока пикселей, сбор выхода, нарезка на кадры.

Поток — valid/sof/data (см. conv2d_stage.sv): пиксель в такте с valid = 1, sof = 1 у первого
пикселя кадра, пиксели по строкам.
"""

import random

import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

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
