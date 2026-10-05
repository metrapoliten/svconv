"""Тесты кадрового буфера и lcd_output: картинка на выходе совпадает с display_frame() из модели,
интерфейс (DE, периоды строки и кадра) — с параметрами; это проверяет capture_screen(). Параметры
совпадают с lcd_output_tb.sv."""

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from svconv_model import display_frame, sample_image
from svconv_tb import capture_screen

SCREEN = (40, 30)
TOTAL = (40 + 12, 30 + 9)
SRC_W, SRC_H = 16, 12
PIX_PERIOD_NS = 13


async def write_frame(dut, img: np.ndarray) -> None:
    for idx, pixel in enumerate(img.flatten()):
        dut.valid_i.value = 1
        dut.sof_i.value = int(idx == 0)
        dut.data_i.value = int(pixel)
        await RisingEdge(dut.clk_w_i)
    dut.valid_i.value = 0
    dut.sof_i.value = 0


async def screen(dut) -> np.ndarray:
    return await capture_screen(dut.clk_pix_i, dut.de_o, [dut.gray_o], SCREEN, TOTAL, PIX_PERIOD_NS)


async def setup(dut) -> None:
    # Разные несвязанные частоты: запись 10 нс, пиксели 13 нс.
    cocotb.start_soon(Clock(dut.clk_w_i, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.clk_pix_i, PIX_PERIOD_NS, unit="ns").start())
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
async def shows_centered_frame(dut):
    await setup(dut)
    img = sample_image(SRC_W, SRC_H)
    await write_frame(dut, img)
    got = await screen(dut)
    expected = display_frame(img, *SCREEN)
    bad = np.argwhere(got != expected)
    assert not len(bad), (
        f"{len(bad)} mismatching screen pixels, first at {tuple(int(v) for v in bad[0])}: "
        f"got {got[tuple(bad[0])]}, expected {expected[tuple(bad[0])]}"
    )


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
    got = await screen(dut)
    expected = display_frame(img, *SCREEN)
    assert (got == expected).all(), f"{int((got != expected).sum())} mismatching pixels"
