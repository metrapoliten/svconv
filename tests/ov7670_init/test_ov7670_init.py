"""Тест ov7670_init и sccb_writer: модель SCCB-устройства декодирует линии и проверяет
протокол, порядок записей по таблице и временные паузы."""

import os
import re
from pathlib import Path

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from svconv_tb import SccbMonitor, check_ov7670_setup, start_clock

CLK_FREQ = int(os.environ["CLK_FREQ"])
MS = CLK_FREQ // 1000

# Ожидаемая таблица — из исходника модуля: по ней проверяются передача и порядок записей.
# Значения ключевых регистров проверяет check_ov7670_setup по даташиту.
TABLE = [
    (int(reg, 16), int(val, 16))
    for reg, val in re.findall(
        r"7'd\d+:\s*ov7670_reg = 16'h([0-9A-F]{2})_([0-9A-F]{2});",
        (Path(__file__).resolve().parents[2] / "rtl/camera/ov7670_init.sv").read_text(),
    )
]


@cocotb.test()
async def writes_whole_table(dut):
    start_clock(dut)
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0
    monitor = SccbMonitor(
        dut.clk_i, lambda: (1 - int(dut.sioc_oe_o.value), 1 - int(dut.siod_oe_o.value))
    )
    cocotb.start_soon(monitor.run())

    # Аппаратный сброс: RESET# = 0 не меньше 1 мс.
    reset_cycles = 0
    while dut.cam_rst_n_o.value == 0:
        await RisingEdge(dut.clk_i)
        reset_cycles += 1
    assert reset_cycles >= MS, f"RESET# low for {reset_cycles} cycles"
    assert dut.cam_pwdn_o.value == 0

    timeout = 20 * MS + len(TABLE) * 200
    for _ in range(timeout):
        await RisingEdge(dut.clk_i)
        if dut.done_o.value == 1:
            break
    assert dut.done_o.value == 1, f"done_o not set; writes so far: {len(monitor.writes)}"
    await ClockCycles(dut.clk_i, 10)

    got = [(dev, reg, val) for _, dev, reg, val in monitor.writes]
    assert len(TABLE) == 80
    assert got == [(0x42, reg, val) for reg, val in TABLE], "SCCB writes differ from the table"
    # Первая запись — программный сброс, после неё пауза не меньше 10 мс.
    assert TABLE[0] == (0x12, 0x80)
    gap = monitor.writes[1][0] - monitor.writes[0][0]
    assert gap >= 10 * MS, f"pause after soft reset: {gap} cycles"
    # Смысл итоговых значений — по даташиту, независимо от таблицы в исходнике.
    check_ov7670_setup(monitor.writes)
