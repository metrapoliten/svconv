"""Тесты conv2d_stage: побитовая сверка с эталонной моделью (model/svconv_model.py).

Размеры кадра и окна задаются при сборке (см. Makefile) и передаются сюда через окружение.
"""

import os
import random

import cocotb
import numpy as np
from cocotb.triggers import ClockCycles

from svconv_model import KERNELS, Kernel, convolve, pad_kernel
from svconv_tb import (
    assert_frames_equal,
    collect,
    drive,
    pack_weights,
    reset,
    split_frames,
    start_clock,
)

WIDTH = int(os.environ["WIDTH"])
HEIGHT = int(os.environ["HEIGHT"])
K = int(os.environ["K"])

# Ядра 5×5 не помещаются в каскад с окном меньше 5×5.
needs_k5 = cocotb.skipif(K < 5, reason="ядро 5×5 не помещается в окно каскада")


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
        kernel = pad_kernel(KERNELS[kernel], K)
    start_clock(dut)
    dut.weights_i.value = pack_weights(kernel.weights)
    dut.shift_i.value = kernel.shift
    dut.abs_i.value = int(kernel.mode == "abs")
    await reset(dut)

    rng = random.Random(seed)
    np_rng = np.random.default_rng(seed)
    frames = [np_rng.integers(0, 256, (HEIGHT, WIDTH), dtype=np.uint8) for _ in range(num_frames)]
    out: list[tuple[int, int]] = []
    cocotb.start_soon(collect(dut, out))
    # Последний кадр — «досылка»: пока он идёт, выходят нижние строки предпоследнего.
    await drive(dut, frames, gap_prob, rng)
    await ClockCycles(dut.clk_i, 20)

    got = split_frames(out, WIDTH, HEIGHT)
    # Полностью выходят все кадры, кроме последнего.
    assert len(got) == num_frames - 1, f"вышло полных кадров: {len(got)}"
    # Каждый входной пиксель порождает ровно один выходной.
    assert len(out) == num_frames * WIDTH * HEIGHT
    for n, frame in enumerate(got):
        assert_frames_equal(frame, convolve(frames[n], kernel), f"кадр {n}")


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

