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
    assert dut.ready_o.value == 1, "kernels were not loaded"

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
    assert len(got) == expected_frames, f"complete frames: {len(got)}, expected {expected_frames}"
    assert len(out) == num_frames * WIDTH * HEIGHT
    for n, frame in enumerate(got):
        assert_frames_equal(frame, pipeline(frames[n], chain), f"frame {n}")


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


@cocotb.test()
async def ready_waits_for_every_stage(dut):
    """ready_o = 1, только когда все каскады загрузили выбранные ядра: смена ядра у одного
    каскада снимает ready_o, пока именно он загружается."""
    start_clock(dut)
    dut.stage_en_i.value = (1 << NUM_STAGES) - 1
    kernels = ["gauss5", "gauss5", "log5"]
    dut.kernel_sel_i.value = sum(sel(name) << (s * SEL_W) for s, name in enumerate(kernels))
    await reset(dut)
    await ClockCycles(dut.clk_i, 4 * K * K)
    assert dut.ready_o.value == 1, "kernels were not loaded"

    kernels[NUM_STAGES - 1] = "identity"
    dut.kernel_sel_i.value = sum(sel(name) << (s * SEL_W) for s, name in enumerate(kernels))
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    assert dut.ready_o.value == 0, "ready_o stays high while the last stage reloads"
    await ClockCycles(dut.clk_i, 4 * K * K)
    assert dut.ready_o.value == 1, "the last stage did not finish loading"


@cocotb.test()
async def clean_frame_after_reconfiguration(dut):
    """Контракт из описания conv_pipeline: после смены конфигурации посреди непрерывного потока
    выходной кадр, начавшийся со второго sof_o после ready_o, целиком вычислен новой
    конфигурацией (кадры вокруг смены могут быть смешанными)."""
    start_clock(dut)
    configs = [
        (["gauss5", "gauss5", "log5"], [True, True, True]),
        (["gauss5", "identity", "log5"], [True, False, True]),
        (["log5", "gauss5", "identity"], [True, True, False]),
    ]

    def apply(cfg) -> None:
        kernels, enabled = cfg
        dut.stage_en_i.value = sum(int(e) << s for s, e in enumerate(enabled))
        dut.kernel_sel_i.value = sum(sel(n) << (s * SEL_W) for s, n in enumerate(kernels))

    apply(configs[0])
    await reset(dut)
    rng = random.Random(9)
    np_rng = np.random.default_rng(9)
    num_changes = 8
    frames = [
        np_rng.integers(0, 256, (HEIGHT, WIDTH), dtype=np.uint8) for _ in range(5 * num_changes + 6)
    ]

    # Выход с номером такта: (такт, sof, данные).
    out: list[tuple[int, int, int]] = []
    cycle = 0

    async def monitor() -> None:
        nonlocal cycle
        while True:
            await RisingEdge(dut.clk_i)
            cycle += 1
            if dut.valid_o.value == 1:
                out.append((cycle, int(dut.sof_o.value), int(dut.data_o.value)))

    cocotb.start_soon(monitor())
    cocotb.start_soon(drive(dut, frames, 0.1, rng))
    frame_cycles = WIDTH * HEIGHT

    for n in range(num_changes):
        cfg = configs[1 + n % (len(configs) - 1)] if n % 2 == 0 else configs[0]
        # Смена в разные моменты кадра: от его начала до конца с шагом 1/num_changes.
        await ClockCycles(dut.clk_i, 3 * frame_cycles + n * frame_cycles // num_changes)
        apply(cfg)
        await RisingEdge(dut.clk_i)
        while dut.ready_o.value != 1:
            await RisingEdge(dut.clk_i)
        ready_cycle = cycle
        # Ждём, пока второй после ready_o кадр выйдет целиком.
        while True:
            starts = [i for i, (c, s, _) in enumerate(out) if s and c > ready_cycle]
            if len(starts) >= 2 and len(out) >= starts[1] + WIDTH * HEIGHT:
                break
            await RisingEdge(dut.clk_i)
        got = np.array([d for _, _, d in out[starts[1] : starts[1] + WIDTH * HEIGHT]], dtype=np.uint8)
        got = got.reshape(HEIGHT, WIDTH)
        kernels, enabled = cfg
        chain = [pad_kernel(KERNELS[n], K) for n, e in zip(kernels, enabled) if e]
        assert any((got == pipeline(f, chain)).all() for f in frames), (
            f"{cfg}: second frame after ready_o does not match any input frame"
        )
