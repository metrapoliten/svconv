"""Сквозной тест camera_uart_top — того, что загружается в Primer 20K для работы с камерой:
сброс после включения, камера 640×480, прореживание до 160×120, цепочка по умолчанию
(gauss5 -> gauss5 -> log5). Компьютер ничего не настраивает: первая же выгрузка (серый кадр и
результат) должна совпасть с моделью."""

import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from svconv_model import (
    KERNELS,
    decimate,
    pipeline,
    rgb565_to_rgb888,
    rgb888_to_gray,
)
from svconv_tb import assert_frames_equal, dvp_camera, uart_recv, uart_send

CAM_W, CAM_H, FACTOR = 640, 480, 4
W, H = 160, 120
CLKS_PER_BIT = int(os.environ["CLK_FREQ"]) // int(os.environ["BAUD"])
DEFAULT_CHAIN = ["gauss5", "gauss5", "log5"]  # DefaultSel в camera_uart_top


@cocotb.test()
async def first_capture_after_power_up(dut):
    cocotb.start_soon(Clock(dut.clk27_i, 37, unit="ns").start())
    cocotb.start_soon(Clock(dut.cam_pclk_i, 37, unit="ns").start())  # PCLK = XCLK = 27 МГц
    dut.uart_rx_i.value = 1
    dut.cam_vsync_i.value = 0
    dut.cam_href_i.value = 0
    dut.cam_data_i.value = 0
    await ClockCycles(dut.clk27_i, 200)

    # Один и тот же кадр: какой бы кадр ни захватился, ожидаемый результат один.
    rgb565 = np.random.default_rng(1).integers(0, 1 << 16, (CAM_H, CAM_W), dtype=np.uint16)
    cocotb.start_soon(dvp_camera(dut, [rgb565] * 4, pclk=dut.cam_pclk_i))
    await uart_send(dut, dut.uart_rx_i, b"f", CLKS_PER_BIT, clk=dut.clk27_i)
    data = await uart_recv(
        dut, dut.uart_tx_o, 2 * W * H, CLKS_PER_BIT, timeout_bits=1_000_000, clk=dut.clk27_i
    )
    raw = np.frombuffer(data[: W * H], dtype=np.uint8).reshape(H, W)
    out = np.frombuffer(data[W * H :], dtype=np.uint8).reshape(H, W)

    gray = rgb888_to_gray(rgb565_to_rgb888(decimate(rgb565, FACTOR, W, H)))
    assert_frames_equal(raw, gray, "gray frame")
    assert_frames_equal(out, pipeline(gray, [KERNELS[n] for n in DEFAULT_CHAIN]), "result")
