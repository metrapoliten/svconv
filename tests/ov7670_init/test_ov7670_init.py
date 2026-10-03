"""Тест ov7670_init и sccb_writer: модель SCCB-устройства декодирует линии и проверяет
протокол, порядок записей по таблице и временные паузы."""

import os
import re
from pathlib import Path

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from svconv_tb import start_clock

CLK_FREQ = int(os.environ["CLK_FREQ"])
MS = CLK_FREQ // 1000

# Ожидаемая таблица — из исходника модуля: тест проверяет передачу и порядок, а не значения.
TABLE = [
    (int(reg, 16), int(val, 16))
    for reg, val in re.findall(
        r"7'd\d+:\s*ov7670_reg = 16'h([0-9A-F]{2})_([0-9A-F]{2});",
        (Path(__file__).resolve().parents[2] / "rtl/camera/ov7670_init.sv").read_text(),
    )
]


class SccbMonitor:
    """Декодирует транзакции SCCB по линиям с открытым стоком (уровень = не oe)."""

    def __init__(self, dut):
        self.dut = dut
        self.writes: list[tuple[int, int, int, int]] = []  # (такт старта, устройство, рег, значение)
        self.cycle = 0

    def lines(self) -> tuple[int, int]:
        return 1 - int(self.dut.sioc_oe_o.value), 1 - int(self.dut.siod_oe_o.value)

    async def run(self) -> None:
        prev_c, prev_d = 1, 1
        bits: list[int] | None = None
        start_cycle = 0
        while True:
            await RisingEdge(self.dut.clk_i)
            self.cycle += 1
            c, d = self.lines()
            if c == 1 and prev_c == 1 and prev_d == 1 and d == 0:  # старт
                assert bits is None, "start inside a transaction"
                bits, start_cycle = [], self.cycle
            elif c == 1 and prev_c == 1 and prev_d == 0 and d == 1:  # стоп
                assert bits is not None and len(bits) == 27, f"stop after {bits} bits"
                b = [int("".join(map(str, bits[i * 9 : i * 9 + 8])), 2) for i in range(3)]
                assert all(bits[i * 9 + 8] == 1 for i in range(3)), "ninth bit must be released"
                self.writes.append((start_cycle, *b))
                bits = None
            elif bits is not None and c == 1 and prev_c == 0:  # фронт SIOC
                # После 27 бит фронт SIOC — часть стопа (SIOD поднимется при высоком SIOC).
                if len(bits) < 27:
                    bits.append(d)
            elif c == 1 and prev_c == 1 and d != prev_d and bits is not None:
                raise AssertionError("SIOD changed while SIOC is high inside a transaction")
            prev_c, prev_d = c, d


@cocotb.test()
async def writes_whole_table(dut):
    start_clock(dut)
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0
    monitor = SccbMonitor(dut)
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
    assert len(TABLE) == 78
    assert got == [(0x42, reg, val) for reg, val in TABLE], "SCCB writes differ from the table"
    # Первая запись — программный сброс, после неё пауза не меньше 10 мс.
    assert TABLE[0] == (0x12, 0x80)
    gap = monitor.writes[1][0] - monitor.writes[0][0]
    assert gap >= 10 * MS, f"pause after soft reset: {gap} cycles"
