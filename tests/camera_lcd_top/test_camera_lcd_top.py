"""Сквозной тест camera_lcd_top — того, что загружается в Mega 138K Pro: генератор 50 МГц,
PLL Gowin (35 МГц для дисплея, 25 МГц для XCLK), запуск камеры (аппаратный сброс и настройка
по SCCB — кадры модель камеры выдаёт только после них), камера 640×480, режим по умолчанию
(gauss5 -> gauss5 -> log5), экран 800×480 RGB666 с кадром по центру. Снимок экрана должен
совпасть с моделью. Переключение режимов кнопкой — в tests/camera_lcd_top_modes."""

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge, Timer

from svconv_model import KERNELS, display_frame, pipeline, rgb565_to_rgb888, rgb888_to_gray
from svconv_tb import capture_screen, dvp_camera, ov7670_power_up, start_camera_lcd_top

CAM_W, CAM_H = 640, 480
SCREEN = (800, 480)
# Тайминги дисплея в camera_lcd_top: строка 800 + 392 такта гашения, кадр 480 + 53 строки.
TOTAL = (800 + 392, 480 + 53)
LCD_PERIOD_NS = 1000 / 35
DEFAULT_CHAIN = ["gauss5", "gauss5", "log5"]  # режим 0 в camera_lcd_top


async def measure_period_ns(clk, cycles: int = 100) -> float:
    await RisingEdge(clk)
    start = cocotb.utils.get_sim_time("ns")
    for _ in range(cycles):
        await RisingEdge(clk)
    return (cocotb.utils.get_sim_time("ns") - start) / cycles


@cocotb.test()
async def camera_frame_on_screen(dut):
    await start_camera_lcd_top(dut)
    await Timer(2, unit="us")

    # PLL: частоты из настроек (CLKOUT0 — дисплей, CLKOUT1 — XCLK камеры).
    lcd_period = await measure_period_ns(dut.lcd_clk_o)
    xclk_period = await measure_period_ns(dut.cam_xclk_o)
    assert abs(lcd_period - LCD_PERIOD_NS) < 0.1, f"LCD clock period {lcd_period:.3f} ns"
    assert abs(xclk_period - 1000 / 25) < 0.1, f"XCLK period {xclk_period:.3f} ns"

    await ov7670_power_up(dut, dut.clk50_i)
    # Один и тот же кадр несколько раз: буфер кадра одинарный, так на экране не будет разрыва.
    rgb565 = np.random.default_rng(1).integers(0, 1 << 16, (CAM_H, CAM_W), dtype=np.uint16)
    await dvp_camera(dut, [rgb565] * 3, pclk=dut.cam_pclk_i)
    # LED3 (led_n_o[3], активный 0) — ядра загружены.
    assert int(dut.led_n_o.value) & 0b1000 == 0, "kernels are not loaded"
    # Снимок — так, как его принимает панель: по спаду DCLK на выводах разъёма (ILI6122 при
    # CLKPOL = L), с проверкой структуры DE и периодов.
    screen = await capture_screen(
        dut.lcd_clk_o,
        dut.lcd_de_o,
        dut.lcd_r_o,
        dut.lcd_g_o,
        dut.lcd_b_o,
        SCREEN,
        TOTAL,
        LCD_PERIOD_NS,
    )

    gray = rgb888_to_gray(rgb565_to_rgb888(rgb565))
    expected = display_frame(pipeline(gray, [KERNELS[n] for n in DEFAULT_CHAIN]), *SCREEN)
    bad = np.argwhere(screen != expected)
    assert not len(bad), (
        f"{len(bad)} mismatching screen pixels, first at {tuple(int(v) for v in bad[0])}: "
        f"got {screen[tuple(bad[0])]:05x}, expected {expected[tuple(bad[0])]:05x}"
    )
