"""Тесты kernel_rom: после выбора ядра выходы совпадают с ядром из модели."""

import os
import random

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from svconv_model import KERNEL_ROM_ORDER, KERNELS, pad_kernel
from svconv_tb import start_clock, unpack_weights

K = int(os.environ["K"])
# Загрузка записи из K*K + 1 байт плюс такты на выдачу адреса и фиксацию.
LOAD_CYCLES = K * K + 3


async def setup(dut, sel: int) -> None:
    start_clock(dut)
    dut.sel_i.value = sel
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0


async def wait_ready(dut, max_cycles: int) -> int:
    """Ждёт ready_o и возвращает число тактов ожидания."""
    for cycle in range(max_cycles + 1):
        await RisingEdge(dut.clk_i)
        if dut.ready_o.value == 1:
            return cycle
    raise AssertionError(f"ready_o not asserted within {max_cycles} cycles")


def check_outputs(dut, sel: int) -> None:
    name = KERNEL_ROM_ORDER[sel]
    if KERNELS[name].size > K:
        return
    kernel = pad_kernel(KERNELS[name], K)
    got = unpack_weights(int(dut.weights_o.value), K)
    assert (got == kernel.weights).all(), f"{name}: weights\n{got}\nexpected\n{kernel.weights}"
    assert int(dut.shift_o.value) == kernel.shift, f"{name}: shift"
    assert int(dut.abs_o.value) == int(kernel.mode == "abs"), f"{name}: mode"


@cocotb.test()
async def loads_after_reset(dut):
    await setup(dut, sel=0)
    await wait_ready(dut, LOAD_CYCLES)
    check_outputs(dut, 0)


@cocotb.test()
async def switches_between_all_kernels(dut):
    """Перебор ядер в случайном порядке, каждое по два раза."""
    await setup(dut, sel=0)
    await wait_ready(dut, LOAD_CYCLES)
    order = list(range(len(KERNEL_ROM_ORDER))) * 2
    random.Random(1).shuffle(order)
    for sel in order:
        dut.sel_i.value = sel
        await wait_ready(dut, LOAD_CYCLES)
        check_outputs(dut, sel)


@cocotb.test()
async def change_during_load(dut):
    """Смена выбора посреди загрузки: в итоге загружено последнее выбранное ядро."""
    last = len(KERNEL_ROM_ORDER) - 1
    await setup(dut, sel=0)
    await ClockCycles(dut.clk_i, K)
    dut.sel_i.value = last
    await wait_ready(dut, 2 * LOAD_CYCLES)
    check_outputs(dut, last)


@cocotb.test()
async def ready_drops_on_change(dut):
    await setup(dut, sel=0)
    await wait_ready(dut, LOAD_CYCLES)
    dut.sel_i.value = 1
    # ready_o комбинационно зависит от sel_i: сразу после смены он равен 0.
    await RisingEdge(dut.clk_i)
    assert dut.ready_o.value == 0
    await wait_ready(dut, LOAD_CYCLES)
    check_outputs(dut, 1)
