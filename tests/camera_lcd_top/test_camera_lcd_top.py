"""Сквозной тест camera_lcd_top — того, что загружается в Mega 138K Pro: генератор 50 МГц,
PLL Gowin (35 МГц для дисплея, 25 МГц для XCLK), камера 640×480, режим по умолчанию
(gauss5 -> gauss5 -> log5), экран 800×480 RGB666 с кадром по центру. Снимок экрана должен
совпасть с моделью."""

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from svconv_model import KERNELS, display_frame, pipeline, rgb565_to_rgb888, rgb888_to_gray
from svconv_tb import dvp_camera

CAM_W, CAM_H = 640, 480
SCREEN_W, SCREEN_H = 800, 480
BITS = (6, 6, 6)
DEFAULT_CHAIN = ["gauss5", "gauss5", "log5"]  # режим 0 в camera_lcd_top


async def capture_screen(dut) -> np.ndarray:
    """Один кадр экрана: пиксели с DE = 1, выбранные по фронту тактового сигнала дисплея."""
    await FallingEdge(dut.lcd_vsync)  # внутренний сигнал: на разъём не выводится (режим DE)
    pixels = []
    while len(pixels) < SCREEN_W * SCREEN_H:
        await RisingEdge(dut.lcd_clk_o)
        if dut.lcd_de_o.value == 1:
            r, g, b = int(dut.lcd_r_o.value), int(dut.lcd_g_o.value), int(dut.lcd_b_o.value)
            pixels.append((r << (BITS[1] + BITS[2])) | (g << BITS[2]) | b)
    return np.array(pixels, dtype=np.uint32).reshape(SCREEN_H, SCREEN_W)


async def measure_period_ns(clk, cycles: int = 100) -> float:
    await RisingEdge(clk)
    start = cocotb.utils.get_sim_time("ns")
    for _ in range(cycles):
        await RisingEdge(clk)
    return (cocotb.utils.get_sim_time("ns") - start) / cycles


@cocotb.test()
async def camera_frame_on_screen(dut):
    cocotb.start_soon(Clock(dut.clk50_i, 20, unit="ns").start())
    # PCLK камеры — 25 МГц, как XCLK от PLL (у OV7670 без делителя PCLK = XCLK).
    cocotb.start_soon(Clock(dut.cam_pclk_i, 40, unit="ns").start())
    dut.btn_n_i.value = 1
    dut.cam_vsync_i.value = 0
    dut.cam_href_i.value = 0
    dut.cam_data_i.value = 0
    await Timer(2, unit="us")

    # PLL: частоты из настроек (CLKOUT0 — дисплей, CLKOUT1 — XCLK камеры).
    lcd_period = await measure_period_ns(dut.lcd_clk_o)
    xclk_period = await measure_period_ns(dut.cam_xclk_o)
    assert abs(lcd_period - 1000 / 35) < 0.1, f"LCD clock period {lcd_period:.3f} ns"
    assert abs(xclk_period - 1000 / 25) < 0.1, f"XCLK period {xclk_period:.3f} ns"

    # Один и тот же кадр несколько раз: буфер кадра одинарный, так на экране не будет разрыва.
    rgb565 = np.random.default_rng(1).integers(0, 1 << 16, (CAM_H, CAM_W), dtype=np.uint16)
    await dvp_camera(dut, [rgb565] * 3, pclk=dut.cam_pclk_i)
    # LED3 (led_n_o[3], активный 0) — ядра загружены.
    assert int(dut.led_n_o.value) & 0b1000 == 0, "kernels are not loaded"
    screen = await capture_screen(dut)

    gray = rgb888_to_gray(rgb565_to_rgb888(rgb565))
    expected = display_frame(
        pipeline(gray, [KERNELS[n] for n in DEFAULT_CHAIN]), SCREEN_W, SCREEN_H, 1, BITS
    )
    bad = np.argwhere(screen != expected)
    assert not len(bad), (
        f"{len(bad)} mismatching screen pixels, first at {tuple(int(v) for v in bad[0])}: "
        f"got {screen[tuple(bad[0])]:05x}, expected {expected[tuple(bad[0])]:05x}"
    )
