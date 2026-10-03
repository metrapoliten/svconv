"""Тесты rgb565_to_gray: совпадение с моделью и прохождение признаков потока.

Значения сигналов читаются сразу по фронту — это значения до его обновления.
"""

import random

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge

from svconv_model import rgb565_to_rgb888, rgb888_to_gray
from svconv_tb import reset, start_clock


def model_gray(pix: int) -> int:
    return int(rgb888_to_gray(rgb565_to_rgb888(np.array([pix])))[0])


@cocotb.test()
async def matches_model_with_one_cycle_latency(dut):
    """Крайние и случайные пиксели вперемешку с паузами; выход отстаёт ровно на 1 такт."""
    start_clock(dut)
    await reset(dut)
    rng = random.Random(2)
    extremes = [0x0000, 0xFFFF, 0xF800, 0x07E0, 0x001F]
    prev = None
    for idx in range(1000):
        pix = extremes[idx] if idx < len(extremes) else rng.randrange(1 << 16)
        valid = idx < len(extremes) or rng.random() < 0.7
        sof = rng.random() < 0.05
        dut.valid_i.value = int(valid)
        dut.sof_i.value = int(sof)
        dut.data_i.value = pix
        await RisingEdge(dut.clk_i)
        # Читаются значения до обновления этим фронтом — они получены из входа прошлого такта.
        if prev is not None:
            p_valid, p_sof, p_pix = prev
            assert dut.valid_o.value == int(p_valid), f"такт {idx}: valid"
            assert dut.sof_o.value == int(p_valid and p_sof), f"такт {idx}: sof"
            if p_valid:
                assert int(dut.data_o.value) == model_gray(p_pix), f"такт {idx}: {p_pix:04x}"
        prev = (valid, sof, pix)
