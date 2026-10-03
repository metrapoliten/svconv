"""Сквозной тест camera_display: кадр с модели камеры DVP появляется на экране LCD так, как
предсказывает модель (прореживание -> серый -> цепочка свёрток -> увеличение и центрирование).
Размеры совпадают с параметрами в Makefile."""

import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from svconv_model import (
    KERNEL_ROM_ORDER,
    KERNELS,
    decimate,
    display_frame,
    pad_kernel,
    pipeline,
    rgb565_to_rgb888,
    rgb888_to_gray,
)

K = int(os.environ["K"])
CAM_W, CAM_H, FACTOR = 64, 48, 4
W, H = 16, 12
SCREEN_W, SCREEN_H, SCALE = 40, 30, 2
SEL_W = max(1, (len(KERNEL_ROM_ORDER) - 1).bit_length())
# Гашение камеры в тактах PCLK.
H_BLANK, V_BLANK, VSYNC_LEN = 20, 50, 10


async def camera(dut, frame: np.ndarray, num_frames: int) -> None:
    """Модель камеры DVP: VSYNC, затем строки с HREF, пиксель RGB565 — два байта, старший первым.
    Данные меняются после фронта PCLK и выбираются ПЛИС на следующем фронте."""
    for _ in range(num_frames):
        dut.cam_vsync_i.value = 1
        await ClockCycles(dut.pclk_i, VSYNC_LEN)
        dut.cam_vsync_i.value = 0
        await ClockCycles(dut.pclk_i, V_BLANK)
        for row in frame:
            dut.cam_href_i.value = 1
            for pixel in row:
                for byte in (int(pixel) >> 8, int(pixel) & 0xFF):
                    dut.cam_data_i.value = byte
                    await RisingEdge(dut.pclk_i)
            dut.cam_href_i.value = 0
            await ClockCycles(dut.pclk_i, H_BLANK)


async def capture_screen(dut) -> np.ndarray:
    await FallingEdge(dut.lcd_vsync_o)
    pixels = []
    while len(pixels) < SCREEN_W * SCREEN_H:
        await RisingEdge(dut.lcd_clk_i)
        if dut.lcd_de_o.value == 1:
            r, g, b = int(dut.lcd_r_o.value), int(dut.lcd_g_o.value), int(dut.lcd_b_o.value)
            pixels.append((r << 11) | (g << 5) | b)
    return np.array(pixels, dtype=np.uint16).reshape(SCREEN_H, SCREEN_W)


async def run(dut, kernels: list[str], enabled: list[bool], seed: int) -> None:
    cocotb.start_soon(Clock(dut.pclk_i, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.lcd_clk_i, 13, unit="ns").start())
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
    await camera(dut, rgb565, num_frames=4)
    screen = await capture_screen(dut)

    gray = rgb888_to_gray(rgb565_to_rgb888(decimate(rgb565, FACTOR, W, H)))
    chain = [pad_kernel(KERNELS[n], K) for n, e in zip(kernels, enabled) if e]
    expected = display_frame(pipeline(gray, chain), SCREEN_W, SCREEN_H, SCALE)
    bad = np.argwhere(screen != expected)
    assert not len(bad), (
        f"{len(bad)} mismatching screen pixels, first at {tuple(int(v) for v in bad[0])}: "
        f"got {screen[tuple(bad[0])]:04x}, expected {expected[tuple(bad[0])]:04x}"
    )
    # Выходной кадр выходит, пока идёт следующий входной: полностью вышли 3 из 4.
    assert frames_seen >= 3, f"processed frames: {frames_seen}"


@cocotb.test()
async def blur_blur_edges(dut):
    await run(dut, ["gauss5", "gauss5", "log5"], [True, True, True], seed=1)


@cocotb.test()
async def all_bypassed(dut):
    """Без свёрток: на экране прореженный серый кадр камеры."""
    await run(dut, ["identity"] * 3, [False] * 3, seed=2)
