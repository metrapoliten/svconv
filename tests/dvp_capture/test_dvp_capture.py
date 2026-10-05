"""Тесты dvp_capture: сборка пикселей RGB565 из байтов DVP, признаки начала кадра и строки,
восстановление после сбоя в строке и начало работы посреди кадра."""

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

W, H = 8, 5
H_BLANK, V_BLANK, VSYNC_LEN = 6, 10, 4


async def setup(dut) -> None:
    cocotb.start_soon(Clock(dut.pclk_i, 10, unit="ns").start())
    dut.vsync_i.value = 0
    dut.href_i.value = 0
    dut.data_i.value = 0
    dut.rst_i.value = 1
    await ClockCycles(dut.pclk_i, 3)
    dut.rst_i.value = 0


async def send_line(dut, line_bytes: list[int]) -> None:
    dut.href_i.value = 1
    for byte in line_bytes:
        dut.data_i.value = byte
        await RisingEdge(dut.pclk_i)
    dut.href_i.value = 0
    await ClockCycles(dut.pclk_i, H_BLANK)


def line_bytes(row) -> list[int]:
    return [b for pixel in row for b in (int(pixel) >> 8, int(pixel) & 0xFF)]


async def send_frame(dut, frame: np.ndarray, extra_byte_rows=()) -> None:
    """Кадр: импульс VSYNC, пауза, строки с HREF; в строках из extra_byte_rows — лишний байт
    в конце (сбой: нечётное число байт)."""
    dut.vsync_i.value = 1
    await ClockCycles(dut.pclk_i, VSYNC_LEN)
    dut.vsync_i.value = 0
    await ClockCycles(dut.pclk_i, V_BLANK)
    for r, row in enumerate(frame):
        await send_line(dut, line_bytes(row) + ([0xA5] if r in extra_byte_rows else []))


async def collect(dut, out: list[tuple[int, int, int]]) -> None:
    """Собирает выход: (sof, sol, пиксель) для каждого такта с valid_o = 1."""
    while True:
        await RisingEdge(dut.pclk_i)
        if dut.valid_o.value == 1:
            out.append((int(dut.sof_o.value), int(dut.sol_o.value), int(dut.data_o.value)))


def random_frame(seed: int) -> np.ndarray:
    return np.random.default_rng(seed).integers(0, 1 << 16, (H, W), dtype=np.uint16)


def rows_of(out: list[tuple[int, int, int]]) -> list[list[int]]:
    """Делит выход на строки по sol_o."""
    rows: list[list[int]] = []
    for _, sol, pixel in out:
        if sol:
            rows.append([])
        assert rows, "a pixel before the first line start"
        rows[-1].append(pixel)
    return rows


@cocotb.test()
async def frames_are_assembled(dut):
    """Два кадра подряд: пиксели {первый байт, второй байт}, sof у первого пикселя кадра, sol —
    у первого пикселя каждой строки."""
    await setup(dut)
    out: list[tuple[int, int, int]] = []
    cocotb.start_soon(collect(dut, out))
    frames = [random_frame(1), random_frame(2)]
    for frame in frames:
        await send_frame(dut, frame)
    await ClockCycles(dut.pclk_i, 4)
    assert len(out) == 2 * W * H, f"{len(out)} pixels, expected {2 * W * H}"
    for f, frame in enumerate(frames):
        part = out[f * W * H : (f + 1) * W * H]
        assert [p for _, _, p in part] == [int(v) for v in frame.flatten()], f"frame {f} pixels"
        assert [s for s, _, _ in part] == [1] + [0] * (W * H - 1), f"frame {f}: sof"
        assert [s for _, s, _ in part] == ([1] + [0] * (W - 1)) * H, f"frame {f}: sol"


@cocotb.test()
async def extra_byte_does_not_shift_next_lines(dut):
    """Лишний байт в конце строки (сбой) не сдвигает следующие строки: незавершённый пиксель
    отбрасывается в паузе между строками, и фаза байтов начинается заново."""
    await setup(dut)
    out: list[tuple[int, int, int]] = []
    cocotb.start_soon(collect(dut, out))
    frame = random_frame(3)
    await send_frame(dut, frame, extra_byte_rows={1})
    await ClockCycles(dut.pclk_i, 4)
    rows = rows_of(out)
    assert len(rows) == H, f"{len(rows)} lines, expected {H}"
    for r in range(H):
        assert rows[r] == [int(v) for v in frame[r]], f"line {r} is wrong"


@cocotb.test()
async def capture_starts_at_vsync(dut):
    """Выход из сброса посреди кадра: его хвост уходит без sof, первый sof — у кадра после VSYNC."""
    await setup(dut)
    out: list[tuple[int, int, int]] = []
    cocotb.start_soon(collect(dut, out))
    tail = random_frame(4)[2:]
    for row in tail:
        await send_line(dut, line_bytes(row))
    frame = random_frame(5)
    await send_frame(dut, frame)
    await ClockCycles(dut.pclk_i, 4)
    sofs = [i for i, (sof, _, _) in enumerate(out) if sof]
    assert sofs == [len(tail) * W], f"sof at {sofs}, expected only at {len(tail) * W}"
    assert [p for _, _, p in out[sofs[0] :]] == [int(v) for v in frame.flatten()]
