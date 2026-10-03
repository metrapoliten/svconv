"""Тесты кадрового буфера и lcd_output: картинка на выходе совпадает с display_frame()
из модели, тайминги соответствуют параметрам. Параметры совпадают с lcd_output_tb.sv."""

import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from svconv_model import display_frame, sample_image

H_ACTIVE, H_FRONT, H_SYNC, H_BACK = 40, 3, 4, 5
V_ACTIVE, V_FRONT, V_SYNC, V_BACK = 30, 2, 3, 4
H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK
V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK
SRC_W, SRC_H = 16, 12
SCALE = int(os.environ["SCALE"])
BITS = tuple(int(v) for v in os.environ["BITS"].split(","))


async def write_frame(dut, img: np.ndarray) -> None:
    for idx, pixel in enumerate(img.flatten()):
        dut.valid_i.value = 1
        dut.sof_i.value = int(idx == 0)
        dut.data_i.value = int(pixel)
        await RisingEdge(dut.clk_w_i)
    dut.valid_i.value = 0
    dut.sof_i.value = 0


async def capture_screen(dut) -> np.ndarray:
    """Снимает один кадр с выхода LCD: от спада vsync до следующего, пиксели с de = 1."""
    await FallingEdge(dut.vsync_o)
    pixels = []
    while True:
        await RisingEdge(dut.clk_pix_i)
        if dut.vsync_o.value == 0 and pixels and len(pixels) >= H_ACTIVE * V_ACTIVE:
            break
        if dut.de_o.value == 1:
            r, g, b = int(dut.r_o.value), int(dut.g_o.value), int(dut.b_o.value)
            pixels.append((r << (BITS[1] + BITS[2])) | (g << BITS[2]) | b)
    assert len(pixels) == H_ACTIVE * V_ACTIVE, f"de pixels per frame: {len(pixels)}"
    return np.array(pixels, dtype=np.uint32).reshape(V_ACTIVE, H_ACTIVE)


async def setup(dut) -> None:
    # Разные несвязанные частоты: запись 10 нс, пиксели 13 нс.
    cocotb.start_soon(Clock(dut.clk_w_i, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.clk_pix_i, 13, unit="ns").start())
    dut.valid_i.value = 0
    dut.sof_i.value = 0
    dut.data_i.value = 0
    dut.rst_w_i.value = 1
    dut.rst_pix_i.value = 1
    await ClockCycles(dut.clk_w_i, 3)
    await ClockCycles(dut.clk_pix_i, 3)
    dut.rst_w_i.value = 0
    dut.rst_pix_i.value = 0


@cocotb.test()
async def shows_scaled_centered_frame(dut):
    await setup(dut)
    img = sample_image(SRC_W, SRC_H)
    await write_frame(dut, img)
    screen = await capture_screen(dut)
    expected = display_frame(img, H_ACTIVE, V_ACTIVE, SCALE, BITS)
    bad = np.argwhere(screen != expected)
    assert not len(bad), (
        f"{len(bad)} mismatching screen pixels, first at {tuple(int(v) for v in bad[0])}: "
        f"got {screen[tuple(bad[0])]:04x}, expected {expected[tuple(bad[0])]:04x}"
    )


@cocotb.test()
async def timing_matches_parameters(dut):
    """Период строки и кадра, длительности синхроимпульсов, число пикселей с de в строке."""
    await setup(dut)
    await FallingEdge(dut.vsync_o)
    # Одна полная развёртка кадра: считаем такты, строки и импульсы.
    cycles = hs_pulses = vs_low = 0
    de_per_line: list[int] = []
    de_count = 0
    prev_hs = 1
    hs_low_len = []
    hs_len = 0
    while True:
        await RisingEdge(dut.clk_pix_i)
        cycles += 1
        hs, vs, de = int(dut.hsync_o.value), int(dut.vsync_o.value), int(dut.de_o.value)
        vs_low += vs == 0
        de_count += de
        if hs == 0:
            hs_len += 1
        if prev_hs == 1 and hs == 0:
            hs_pulses += 1
            if de_count:
                de_per_line.append(de_count)
            de_count = 0
        if prev_hs == 0 and hs == 1:
            hs_low_len.append(hs_len)
            hs_len = 0
        prev_hs = hs
        if cycles == H_TOTAL * V_TOTAL:
            break
    assert hs_pulses == V_TOTAL, f"hsync pulses per frame: {hs_pulses}"
    assert set(hs_low_len) == {H_SYNC}, f"hsync widths: {set(hs_low_len)}"
    assert vs_low == V_SYNC * H_TOTAL, f"vsync low cycles: {vs_low}"
    assert de_per_line and set(de_per_line) == {H_ACTIVE}, f"de per line: {set(de_per_line)}"
    assert len(de_per_line) == V_ACTIVE, f"lines with de: {len(de_per_line)}"


@cocotb.test()
async def write_restarts_at_sof(dut):
    """Поток без sof и оборванный кадр не мешают: следующий кадр пишется с начала буфера."""
    await setup(dut)
    rng = np.random.default_rng(3)
    for pixel in rng.integers(0, 256, SRC_W * SRC_H // 3):  # без sof
        dut.valid_i.value = 1
        dut.sof_i.value = 0
        dut.data_i.value = int(pixel)
        await RisingEdge(dut.clk_w_i)
    partial = rng.integers(0, 256, (SRC_H, SRC_W), dtype=np.uint8)
    for idx, pixel in enumerate(partial.flatten()[: SRC_W * SRC_H // 2]):  # оборванный кадр
        dut.valid_i.value = 1
        dut.sof_i.value = int(idx == 0)
        dut.data_i.value = int(pixel)
        await RisingEdge(dut.clk_w_i)
    img = sample_image(SRC_W, SRC_H)
    await write_frame(dut, img)
    screen = await capture_screen(dut)
    expected = display_frame(img, H_ACTIVE, V_ACTIVE, SCALE, BITS)
    assert (screen == expected).all(), f"{int((screen != expected).sum())} mismatching pixels"
