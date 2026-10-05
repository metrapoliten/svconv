"""Сквозной тест camera_lcd_top — того, что загружается в Mega 138K Pro: генератор 50 МГц,
PLL Gowin (35 МГц для дисплея, 25 МГц для XCLK), запуск камеры (аппаратный сброс и настройка
по SCCB — кадры модель камеры выдаёт только после них), камера 640×480, режим по умолчанию
(gauss5 -> gauss5 -> log5), экран 800×480 RGB666 с кадром по центру. Снимок экрана должен
совпасть с моделью. Переключение режимов кнопкой — в tests/camera_lcd_top_modes."""

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer, with_timeout

from svconv_model import KERNELS, display_frame, pipeline, rgb565_to_rgb888, rgb888_to_gray
from svconv_tb import dvp_camera, ov7670_power_up

CAM_W, CAM_H = 640, 480
SCREEN_W, SCREEN_H = 800, 480
BITS = (6, 6, 6)
# Тайминги дисплея в camera_lcd_top: строка 800 + 210 + 1 + 181 тактов, кадр 480 + 45 + 1 + 7 строк.
H_TOTAL = SCREEN_W + 210 + 1 + 181
V_TOTAL = SCREEN_H + 45 + 1 + 7
LCD_PERIOD_NS = 1000 / 35
DEFAULT_CHAIN = ["gauss5", "gauss5", "log5"]  # режим 0 в camera_lcd_top


def _lcd_outputs(dut) -> tuple[int, int, int, int]:
    return (
        int(dut.lcd_de_o.value),
        int(dut.lcd_r_o.value),
        int(dut.lcd_g_o.value),
        int(dut.lcd_b_o.value),
    )


async def capture_screen(dut, timeout_frames: int = 3) -> np.ndarray:
    """Один кадр экрана — так, как его принимает панель: только по выводам разъёма, сигналы
    выбираются по спаду DCLK (ILI6122 при CLKPOL = L). Проверяет интерфейс: RGB и DE не меняются
    на спаде DCLK, в кадре 480 строк по 800 тактов с DE = 1, период строки — H_TOTAL тактов,
    кадра — V_TOTAL строк. Всё — не дольше timeout_frames кадров дисплея."""
    timeout_ns = round(timeout_frames * V_TOTAL * H_TOTAL * LCD_PERIOD_NS)
    return await with_timeout(_capture_screen(dut), timeout_ns, "ns")


async def _capture_screen(dut) -> np.ndarray:
    cycle = 0

    async def next_sample() -> tuple[int, int, int, int]:
        nonlocal cycle
        await FallingEdge(dut.lcd_clk_o)
        cycle += 1
        sample = _lcd_outputs(dut)
        await ReadOnly()
        assert _lcd_outputs(dut) == sample, f"RGB/DE change at the falling edge of DCLK {cycle}"
        return sample

    # Начало кадра — DE = 1 после паузы длиннее строки (между строками пауза короче).
    idle = 0
    while True:
        de, r, g, b = await next_sample()
        if de and idle > H_TOTAL:
            break
        idle = 0 if de else idle + 1

    frame_start = cycle
    line_starts = []
    pixels = []
    prev_de = 0
    while True:
        if de and not prev_de:  # начало строки
            if len(line_starts) == SCREEN_H:  # первая строка следующего кадра
                break
            line_starts.append(cycle)
        if de:
            pixels.append((r << (BITS[1] + BITS[2])) | (g << BITS[2]) | b)
        if not de and prev_de:  # конец строки
            run = cycle - line_starts[-1]
            assert run == SCREEN_W, f"line {len(line_starts) - 1}: DE = 1 for {run} clocks"
        prev_de = de
        de, r, g, b = await next_sample()

    periods = set(np.diff(line_starts).tolist())
    assert periods == {H_TOTAL}, f"line periods {sorted(periods)} clocks, expected {H_TOTAL}"
    frame = cycle - frame_start
    assert frame == V_TOTAL * H_TOTAL, f"frame period {frame} clocks, expected {V_TOTAL * H_TOTAL}"
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
    # PCLK камеры — 25 МГц, как XCLK от PLL (у OV7670 без делителя PCLK = XCLK); фронты сдвинуты
    # относительно clk50 на задержку проводов и камеры.
    await Timer(7, unit="ns")
    cocotb.start_soon(Clock(dut.cam_pclk_i, 40, unit="ns").start())
    dut.btn_n_i.value = 1
    dut.cam_vsync_i.value = 0
    dut.cam_href_i.value = 0
    dut.cam_data_i.value = 0
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
