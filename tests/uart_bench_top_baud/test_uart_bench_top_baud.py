"""uart_bench_top на рабочей скорости UART: делитель для 115200 бод при 27 МГц (234 такта на
бит) — тот же, что на плате. Проверяются команда p (ответ платы) и разбор команд c (настройка
применяется, команда с несуществующим ядром отбрасывается); настройка читается из регистров
стенда внутри модуля."""

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from svconv_model import KERNEL_ROM_ORDER
from svconv_tb import uart_recv, uart_send

WIDTH, HEIGHT = 160, 120
CLKS_PER_BIT = round(int(os.environ["CLK_FREQ"]) / int(os.environ["BAUD"]))
SEL_W = 2


def chain_bytes(kernels: list[str], enabled: list[bool]) -> tuple[int, int]:
    en = sum(int(e) << s for s, e in enumerate(enabled))
    sel = sum(KERNEL_ROM_ORDER.index(n) << (s * SEL_W) for s, n in enumerate(kernels))
    return en, sel


@cocotb.test()
async def commands_at_board_baud_rate(dut):
    assert CLKS_PER_BIT == 234
    cocotb.start_soon(Clock(dut.clk27_i, 37, unit="ns").start())
    dut.uart_rx_i.value = 1
    clk = dut.clk27_i
    # Несколько кадров, чтобы период был измерен.
    await ClockCycles(clk, 3 * WIDTH * HEIGHT)

    await uart_send(dut, dut.uart_rx_i, b"p", CLKS_PER_BIT, clk=clk)
    period = int.from_bytes(await uart_recv(dut, dut.uart_tx_o, 4, CLKS_PER_BIT, clk=clk), "little")
    assert period == WIDTH * HEIGHT, f"frame period {period}, expected {WIDTH * HEIGHT}"

    en, sel = chain_bytes(["log5", "identity", "gauss5"], [True, False, True])
    await uart_send(dut, dut.uart_rx_i, bytes([ord("c"), en, sel]), CLKS_PER_BIT, clk=clk)
    await ClockCycles(clk, 2 * CLKS_PER_BIT)
    assert int(dut.u_bench.stage_en_q.value) == en, "en byte not applied"
    assert int(dut.u_bench.kernel_sel_q.value) == sel, "sel byte not applied"

    # Номер ядра 3 не существует: команда отбрасывается, настройка прежняя.
    await uart_send(dut, dut.uart_rx_i, bytes([ord("c"), 0b111, 3]), CLKS_PER_BIT, clk=clk)
    await ClockCycles(clk, 2 * CLKS_PER_BIT)
    assert int(dut.u_bench.stage_en_q.value) == en, "invalid command changed en"
    assert int(dut.u_bench.kernel_sel_q.value) == sel, "invalid command changed sel"
