"""Тесты conv_pipeline: цепочка каскадов с ядрами из ПЗУ совпадает с pipeline() из модели."""

import os
import random

import cocotb
import numpy as np
from cocotb.triggers import ClockCycles, RisingEdge

from svconv_model import KERNEL_ROM_ORDER, KERNELS, pad_kernel, pipeline
from svconv_tb import assert_frames_equal, collect, drive, reset, split_frames, start_clock

WIDTH = int(os.environ["WIDTH"])
HEIGHT = int(os.environ["HEIGHT"])
K = int(os.environ["K"])
NUM_STAGES = 3
SEL_W = max(1, (len(KERNEL_ROM_ORDER) - 1).bit_length())


def sel(name: str) -> int:
    return KERNEL_ROM_ORDER.index(name)


async def run_config(
    dut, kernels: list[str], enabled: list[bool], num_frames: int, gap_prob: float, seed: int
) -> None:
    start_clock(dut)
    dut.stage_en_i.value = sum(int(e) << s for s, e in enumerate(enabled))
    dut.kernel_sel_i.value = sum(sel(name) << (s * SEL_W) for s, name in enumerate(kernels))
    await reset(dut)
    for _ in range(4 * K * K):
        await RisingEdge(dut.clk_i)
        if dut.ready_o.value == 1:
            break
    assert dut.ready_o.value == 1, "ядра не загрузились"

    rng = random.Random(seed)
    np_rng = np.random.default_rng(seed)
    frames = [np_rng.integers(0, 256, (HEIGHT, WIDTH), dtype=np.uint8) for _ in range(num_frames)]
    out: list[tuple[int, int]] = []
    cocotb.start_soon(collect(dut, out))
    await drive(dut, frames, gap_prob, rng)
    # Досылка: задержка конвейера каждого каскада — несколько тактов.
    await ClockCycles(dut.clk_i, 20 * NUM_STAGES)

    chain = [pad_kernel(KERNELS[name], K) for name, e in zip(kernels, enabled) if e]
    got = split_frames(out, WIDTH, HEIGHT)
    # Каждый включённый каскад отстаёт на (p + 1) * WIDTH + p пикселей; кадры, хвост которых
    # ещё не вышел к концу подачи, неполные.
    p = K // 2
    lag = len(chain) * ((p + 1) * WIDTH + p)
    expected_frames = num_frames - -(-lag // (WIDTH * HEIGHT))
    assert len(got) == expected_frames, f"полных кадров: {len(got)}, ожидалось {expected_frames}"
    assert len(out) == num_frames * WIDTH * HEIGHT
    for n, frame in enumerate(got):
        assert_frames_equal(frame, pipeline(frames[n], chain), f"кадр {n}")


@cocotb.test()
async def blur_blur_edges(dut):
    """Цепочка из задания: размытие -> размытие -> выделение границ."""
    await run_config(dut, ["gauss5", "gauss5", "log5"], [True] * 3, 5, 0.0, seed=1)


@cocotb.test()
async def blur_blur_edges_with_gaps(dut):
    await run_config(dut, ["gauss5", "gauss5", "log5"], [True] * 3, 5, 0.3, seed=2)


@cocotb.test()
async def all_bypassed(dut):
    """Все каскады выключены: выход совпадает со входом без рамок и без задержки на строки."""
    await run_config(dut, ["gauss5", "gauss5", "log5"], [False] * 3, 3, 0.2, seed=3)


@cocotb.test()
async def middle_stage_bypassed(dut):
    await run_config(dut, ["gauss5", "identity", "log5"], [True, False, True], 4, 0.1, seed=4)


@cocotb.test()
async def edges_only(dut):
    await run_config(dut, ["identity", "identity", "log5"], [False, False, True], 3, 0.0, seed=5)
