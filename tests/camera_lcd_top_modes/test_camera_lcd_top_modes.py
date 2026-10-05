"""Переключение режимов кнопкой в camera_lcd_top на работающей камере (кадр уменьшен, см. Makefile):
после запуска камеры она непрерывно выдаёт один и тот же кадр, а кнопка S1 (активный 0, с
дребезгом) переключает режимы 0 -> 1 -> 2 -> 3 -> 0. После каждого нажатия цепочка загружает ядра
нового режима, и кадровый буфер (его читает вывод на экран) должен заполниться кадром этого режима
— таким, как в модели. Короткая помеха на кнопке режим не меняет."""

import itertools
import os

import cocotb
import numpy as np
from cocotb.triggers import ClockCycles, RisingEdge, with_timeout

from svconv_model import KERNEL_ROM_ORDER, KERNELS, pipeline, rgb565_to_rgb888, rgb888_to_gray
from svconv_tb import dvp_camera, ov7670_power_up, start_camera_lcd_top

CAM_W = int(os.environ["CAM_WIDTH"])
CAM_H = int(os.environ["CAM_HEIGHT"])
BTN_STABLE_CLKS = int(os.environ["BTN_STABLE_CLKS"])
# Цепочки режимов 0..3 в camera_lcd_top ('-' — стадия обходится); режим 0 — после сброса.
MODE_CHAINS = [
    ["gauss5", "gauss5", "log5"],
    ["-", "-", "-"],
    ["gauss5", "-", "-"],
    ["-", "-", "log5"],
]
# Ожидание установившегося кадра — не дольше стольких кадров камеры (нужно около четырёх).
SETTLE_TIMEOUT_FRAMES = 10


def led_mode(dut) -> int:
    """Номер режима на LED4, LED5 (активный 0)."""
    return (~int(dut.led_n_o.value) >> 4) & 0b11


def pipeline_chain(dut) -> list[str]:
    """Цепочка, которую получает обработка в домене PCLK: включённые стадии и номера ядер."""
    stage_en, kernel_sel = int(dut.stage_en.value), int(dut.kernel_sel.value)
    return [
        KERNEL_ROM_ORDER[(kernel_sel >> (2 * s)) & 0b11] if (stage_en >> s) & 1 else "-"
        for s in range(3)
    ]


async def bounce(dut, level: int) -> None:
    """Дребезг контактов: несколько переключений короче времени подавления, затем level."""
    for width in (3, BTN_STABLE_CLKS // 2, 7, BTN_STABLE_CLKS - 10):
        dut.btn_n_i.value = level
        await ClockCycles(dut.clk50_i, width)
        dut.btn_n_i.value = 1 - level
        await ClockCycles(dut.clk50_i, 5)
    dut.btn_n_i.value = level


async def press(dut) -> None:
    """Нажатие и отпускание кнопки с дребезгом."""
    await bounce(dut, 0)
    await ClockCycles(dut.clk50_i, 3 * BTN_STABLE_CLKS)  # кнопку держат
    await bounce(dut, 1)
    await ClockCycles(dut.clk50_i, 2 * BTN_STABLE_CLKS)


async def settle(dut, chain: list[str]) -> None:
    """Ждёт, пока в буфере окажется целый кадр цепочки chain. Она дошла до домена PCLK, и ядра
    загружены (ready); после смены каждый переключившийся каскад выравнивается по первому началу
    кадра на своём входе и до этого может выдать лишнее начало кадра. Поэтому начала кадров
    считаются на входе цепочки (см. conv_pipeline.sv): после второго входного все каскады уже
    выровнены, первый кадр на выходе после него чистый, а к следующему он записан целиком."""
    pclk = dut.cam_pclk_i
    pipe = dut.u_display.u_camera.u_pipeline
    while pipeline_chain(dut) != chain:
        await RisingEdge(pclk)
    while not dut.pipe_ready.value:
        await RisingEdge(pclk)
    in_frames = 0
    while in_frames < 2:
        await RisingEdge(pclk)
        in_frames += int(pipe.valid_i.value) & int(pipe.sof_i.value)
    out_frames = 0
    while out_frames < 2:
        await RisingEdge(pclk)
        out_frames += int(dut.frame.value)
    await ClockCycles(pclk, 4)  # запись в буфер — через такт после выхода цепочки


def frame_buffer(dut) -> np.ndarray:
    mem = dut.u_display.u_frame_buffer.mem
    return np.array([int(mem[i].value) for i in range(CAM_W * CAM_H)]).reshape(CAM_H, CAM_W)


async def check_mode(dut, mode: int, gray: np.ndarray, frame_ns: int) -> None:
    chain = MODE_CHAINS[mode]
    await with_timeout(settle(dut, chain), SETTLE_TIMEOUT_FRAMES * frame_ns, "ns")
    assert led_mode(dut) == mode, f"LEDs show mode {led_mode(dut)}, expected {mode}"
    expected = pipeline(gray, [KERNELS[n] for n in chain if n != "-"])
    got = frame_buffer(dut)
    bad = np.argwhere(got != expected)
    assert not len(bad), (
        f"mode {mode} {chain}: {len(bad)} mismatching pixels in the frame buffer, first at "
        f"{tuple(int(v) for v in bad[0])}: got {got[tuple(bad[0])]}, "
        f"expected {expected[tuple(bad[0])]}"
    )
    dut._log.info(f"mode {mode} {chain}: frame buffer matches the model")


@cocotb.test()
async def modes_switch_on_running_camera(dut):
    await start_camera_lcd_top(dut)

    await ov7670_power_up(dut, dut.clk50_i)
    rgb565 = np.random.default_rng(2).integers(0, 1 << 16, (CAM_H, CAM_W), dtype=np.uint16)
    gray = rgb888_to_gray(rgb565_to_rgb888(rgb565))
    cocotb.start_soon(dvp_camera(dut, itertools.repeat(rgb565), pclk=dut.cam_pclk_i))
    # Кадр модели камеры в dvp_camera: VSYNC 10 тактов, 50 пустых, строки по 2 * CAM_W + 20.
    frame_ns = 40 * (10 + 50 + CAM_H * (2 * CAM_W + 20))

    await check_mode(dut, 0, gray, frame_ns)

    # Помеха короче времени подавления дребезга — не нажатие.
    dut.btn_n_i.value = 0
    await ClockCycles(dut.clk50_i, BTN_STABLE_CLKS - 10)
    dut.btn_n_i.value = 1
    await ClockCycles(dut.clk50_i, 2 * BTN_STABLE_CLKS)
    assert led_mode(dut) == 0, "a short glitch on the button changed the mode"

    for mode in (1, 2, 3, 0):
        await press(dut)
        await check_mode(dut, mode, gray, frame_ns)
