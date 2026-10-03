"""Тесты conv2d_stage: побитовая сверка с эталонной моделью (model/svconv_model.py).

Размеры кадра и ядра задаются при сборке (см. Makefile) и передаются сюда через окружение.
"""

import os
import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from svconv_model import KERNELS, Kernel, convolve

WIDTH = int(os.environ["WIDTH"])
HEIGHT = int(os.environ["HEIGHT"])
K = int(os.environ["K"])


# Ядра 5×5 не помещаются в каскад с окном меньше 5×5.
needs_k5 = cocotb.skipif(K < 5, reason="ядро 5×5 не помещается в окно каскада")


def fit_kernel(kernel: Kernel) -> Kernel:
    """Дополняет ядро нулями до K×K: аппаратный каскад всегда работает с окном K×K
    (поэтому и обнуляемая рамка у него шириной K//2, а не kernel.size//2)."""
    pad = (K - kernel.size) // 2
    weights = np.pad(kernel.weights, pad)
    return Kernel(kernel.name, weights, kernel.shift, kernel.mode)


def pack_weights(weights: np.ndarray) -> int:
    """Веса K×K -> вектор weights_i: вес (i, j) в битах [(i*K + j)*8 +: 8]."""
    value = 0
    for idx, w in enumerate(weights.flatten()):
        value |= (int(w) & 0xFF) << (8 * idx)
    return value


async def setup(dut, kernel: Kernel) -> None:
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    dut.weights_i.value = pack_weights(kernel.weights)
    dut.shift_i.value = kernel.shift
    dut.abs_i.value = int(kernel.mode == "abs")
    dut.valid_i.value = 0
    dut.sof_i.value = 0
    dut.data_i.value = 0
    dut.rst_i.value = 1
    for _ in range(3):
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


# Значение неопределённого (X/Z) выходного пикселя.
UNDEFINED = -1


async def collect(dut, out: list[tuple[int, int]]) -> None:
    """Записывает все выходные пиксели как пары (sof, data).

    До первого sof_o на выход идут строки «предыдущего кадра», которого не было: они читаются
    из ещё не записанных буферов и в симуляции не определены (UNDEFINED). Внутри полных кадров
    таких значений быть не должно.
    """
    while True:
        await RisingEdge(dut.clk_i)
        if dut.valid_o.value == 1:
            data = dut.data_o.value
            out.append((int(dut.sof_o.value), int(data) if data.is_resolvable else UNDEFINED))


def split_frames(out: list[tuple[int, int]]) -> list[np.ndarray]:
    """Режет выходной поток на кадры по sof; возвращает только полностью вышедшие кадры."""
    starts = [i for i, (sof, _) in enumerate(out) if sof]
    frames = []
    for s in starts:
        chunk = out[s : s + WIDTH * HEIGHT]
        if len(chunk) == WIDTH * HEIGHT:
            data = [d for _, d in chunk]
            assert UNDEFINED not in data, "неопределённые пиксели внутри кадра"
            frames.append(np.array(data, dtype=np.uint8).reshape(HEIGHT, WIDTH))
    return frames


def random_kernel(mode: str, seed: int) -> Kernel:
    """Несимметричное ядро со случайными весами: ловит путаницу строк/столбцов окна,
    проверяет отрицательные суммы, насыщение и нестандартный сдвиг."""
    rng = np.random.default_rng(seed)
    weights = rng.integers(-128, 128, (K, K))
    return Kernel(f"random_{mode}", weights, shift=int(rng.integers(0, 12)), mode=mode)


async def run_frames(
    dut, kernel: Kernel | str, num_frames: int, gap_prob: float, seed: int
) -> None:
    if isinstance(kernel, str):
        kernel = fit_kernel(KERNELS[kernel])
    await setup(dut, kernel)
    rng = random.Random(seed)
    np_rng = np.random.default_rng(seed)
    frames = [np_rng.integers(0, 256, (HEIGHT, WIDTH), dtype=np.uint8) for _ in range(num_frames)]
    out: list[tuple[int, int]] = []
    cocotb.start_soon(collect(dut, out))
    # Последний кадр — «досылка»: пока он идёт, выходят нижние строки предпоследнего.
    await drive(dut, frames, gap_prob, rng)
    for _ in range(20):
        await RisingEdge(dut.clk_i)

    got = split_frames(out)
    # Полностью выходят все кадры, кроме последнего.
    assert len(got) == num_frames - 1, f"вышло полных кадров: {len(got)}"
    # Каждый входной пиксель порождает ровно один выходной.
    assert len(out) == num_frames * WIDTH * HEIGHT
    for n, frame in enumerate(got):
        expected = convolve(frames[n], kernel)
        mismatches = np.argwhere(frame != expected)
        assert not len(mismatches), (
            f"кадр {n}: {len(mismatches)} несовпадений, первое в (строка, столбец) "
            f"{tuple(mismatches[0])}: получено {frame[tuple(mismatches[0])]}, "
            f"ожидалось {expected[tuple(mismatches[0])]}"
        )


@cocotb.test()
async def identity_back_to_back(dut):
    """Тождественное ядро, пиксели каждый такт: выход = вход (кроме рамки)."""
    await run_frames(dut, "identity", num_frames=3, gap_prob=0.0, seed=1)


@needs_k5
@cocotb.test()
async def gauss5_back_to_back(dut):
    await run_frames(dut, "gauss5", num_frames=3, gap_prob=0.0, seed=2)


@needs_k5
@cocotb.test()
async def log5_back_to_back(dut):
    await run_frames(dut, "log5", num_frames=3, gap_prob=0.0, seed=3)


@needs_k5
@cocotb.test()
async def gauss5_random_gaps(dut):
    """Случайные паузы во входном потоке, как у камеры."""
    await run_frames(dut, "gauss5", num_frames=3, gap_prob=0.5, seed=4)


@needs_k5
@cocotb.test()
async def log5_random_gaps(dut):
    await run_frames(dut, "log5", num_frames=3, gap_prob=0.3, seed=5)


@cocotb.test()
async def random_kernel_clamp(dut):
    await run_frames(dut, random_kernel("clamp", seed=6), num_frames=3, gap_prob=0.2, seed=6)


@cocotb.test()
async def random_kernel_abs(dut):
    await run_frames(dut, random_kernel("abs", seed=7), num_frames=3, gap_prob=0.2, seed=7)
