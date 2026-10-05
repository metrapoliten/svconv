"""Сквозной тест camera_display: кадр с модели камеры DVP появляется на экране LCD так, как
предсказывает модель (серый -> цепочка свёрток -> центрирование).
Размеры совпадают с параметрами в Makefile."""

import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from svconv_model import (
    KERNEL_ROM_ORDER,
    KERNELS,
    display_frame,
    pad_kernel,
    pipeline,
    rgb565_to_rgb888,
    rgb888_to_gray,
)
from svconv_tb import capture_screen, dvp_camera

K = int(os.environ["K"])
CAM_W, CAM_H = 16, 12
SCREEN = (40, 30)
TOTAL = (40 + 12, 30 + 9)
LCD_PERIOD_NS = 13
SEL_W = max(1, (len(KERNEL_ROM_ORDER) - 1).bit_length())


async def run(dut, kernels: list[str], enabled: list[bool], seed: int) -> None:
    cocotb.start_soon(Clock(dut.pclk_i, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.lcd_clk_i, LCD_PERIOD_NS, unit="ns").start())
    dut.stage_en_i.value = sum(int(e) << s for s, e in enumerate(enabled))
    dut.kernel_sel_i.value = sum(
        KERNEL_ROM_ORDER.index(n) << (s * SEL_W) for s, n in enumerate(kernels)
    )
    dut.cam_vsync_i.value = 0
    dut.cam_href_i.value = 0
    dut.cam_data_i.value = 0
    dut.rst_pclk_i.value = 1
    dut.rst_lcd_i.value = 1
    await ClockCycles(dut.pclk_i, 3)
    await ClockCycles(dut.lcd_clk_i, 3)
    dut.rst_pclk_i.value = 0
    dut.rst_lcd_i.value = 0

    frames_seen = 0

    async def count_frames() -> None:
        nonlocal frames_seen
        while True:
            await RisingEdge(dut.pclk_i)
            frames_seen += int(dut.frame_o.value)

    cocotb.start_soon(count_frames())

    # Один и тот же кадр несколько раз: буфер кадра одинарный, так на экране не будет
    # «разрыва» между разными кадрами.
    rgb565 = np.random.default_rng(seed).integers(0, 1 << 16, (CAM_H, CAM_W), dtype=np.uint16)
    await dvp_camera(dut, [rgb565] * 4)
    screen = await capture_screen(
        dut.lcd_clk_i, dut.lcd_de_o, [dut.lcd_gray_o], SCREEN, TOTAL, LCD_PERIOD_NS
    )

    gray = rgb888_to_gray(rgb565_to_rgb888(rgb565))
    chain = [pad_kernel(KERNELS[n], K) for n, e in zip(kernels, enabled) if e]
    expected = display_frame(pipeline(gray, chain), *SCREEN)
    bad = np.argwhere(screen != expected)
    assert not len(bad), (
        f"{len(bad)} mismatching screen pixels, first at {tuple(int(v) for v in bad[0])}: "
        f"got {screen[tuple(bad[0])]}, expected {expected[tuple(bad[0])]}"
    )
    # Выходной кадр выходит, пока идёт следующий входной: полностью вышли 3 из 4.
    assert frames_seen >= 3, f"processed frames: {frames_seen}"


@cocotb.test()
async def blur_blur_edges(dut):
    await run(dut, ["gauss5", "gauss5", "log5"], [True, True, True], seed=1)


@cocotb.test()
async def all_bypassed(dut):
    """Без свёрток: на экране серый кадр камеры."""
    await run(dut, ["identity"] * 3, [False] * 3, seed=2)
