"""Общие функции cocotb-тестов: подача потока пикселей, сбор выхода, нарезка на кадры.

Поток — valid/sof/data (см. conv2d_stage.sv): пиксель в такте с valid = 1, sof = 1 у первого
пикселя кадра, пиксели по строкам.
"""

import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import (
    ClockCycles,
    FallingEdge,
    First,
    ReadOnly,
    RisingEdge,
    Timer,
    with_timeout,
)

# Значение неопределённого (X/Z) выходного пикселя.
UNDEFINED = -1


def start_clock(dut, period_ns: int = 10) -> None:
    cocotb.start_soon(Clock(dut.clk_i, period_ns, unit="ns").start())


async def reset(dut, cycles: int = 3) -> None:
    dut.valid_i.value = 0
    dut.sof_i.value = 0
    dut.data_i.value = 0
    dut.rst_i.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk_i)
    dut.rst_i.value = 0


async def drive(dut, frames: list[np.ndarray], gap_prob: float, rng: random.Random) -> None:
    """Подаёт кадры подряд; с вероятностью gap_prob перед пикселем вставляется пауза."""
    for frame in frames:
        for idx, pixel in enumerate(frame.flatten()):
            while rng.random() < gap_prob:
                dut.valid_i.value = 0
                await RisingEdge(dut.clk_i)
            dut.valid_i.value = 1
            dut.sof_i.value = int(idx == 0)
            dut.data_i.value = int(pixel)
            await RisingEdge(dut.clk_i)
    dut.valid_i.value = 0
    dut.sof_i.value = 0


async def collect(dut, out: list[tuple[int, int]]) -> None:
    """Записывает все выходные пиксели как пары (sof, data).

    До первого sof_o на выход идут строки «предыдущего кадра», которого не было: они читаются
    из ещё не записанных буферов и в симуляции не определены (UNDEFINED). Внутри полных кадров
    таких значений быть не должно — это проверяет split_frames().
    """
    while True:
        await RisingEdge(dut.clk_i)
        if dut.valid_o.value == 1:
            data = dut.data_o.value
            out.append((int(dut.sof_o.value), int(data) if data.is_resolvable else UNDEFINED))


def split_frames(out: list[tuple[int, int]], width: int, height: int) -> list[np.ndarray]:
    """Режет выходной поток на кадры по sof; возвращает только полностью вышедшие кадры.

    Заодно проверяет расстановку sof: между соседними sof ровно width*height пикселей, а после
    последнего — не больше (иначе лишний или потерянный sof остался бы незамеченным)."""
    starts = [i for i, (sof, _) in enumerate(out) if sof]
    for a, b in zip(starts, starts[1:]):
        assert b - a == width * height, f"sof at pixels {a} and {b}: {b - a} pixels apart"
    if starts:
        assert len(out) - starts[-1] <= width * height, "pixels after the last frame without sof"
    frames = []
    for s in starts:
        chunk = out[s : s + width * height]
        if len(chunk) == width * height:
            data = [d for _, d in chunk]
            assert UNDEFINED not in data, "undefined pixels inside a frame"
            frames.append(np.array(data, dtype=np.uint8).reshape(height, width))
    return frames


def assert_frames_equal(got: np.ndarray, expected: np.ndarray, label: str) -> None:
    mismatches = np.argwhere(got != expected)
    assert not len(mismatches), (
        f"{label}: {len(mismatches)} mismatches, first at (row, col) "
        f"{tuple(int(v) for v in mismatches[0])}: got {got[tuple(mismatches[0])]}, "
        f"expected {expected[tuple(mismatches[0])]}"
    )


def pack_weights(weights: np.ndarray) -> int:
    """Веса K×K -> вектор weights: вес (i, j) в битах [(i*K + j)*8 +: 8]."""
    value = 0
    for idx, w in enumerate(weights.flatten()):
        value |= (int(w) & 0xFF) << (8 * idx)
    return value


def unpack_weights(value: int, k: int) -> np.ndarray:
    """Обратное к pack_weights: вектор весов -> знаковая матрица K×K."""
    raw = [(value >> (8 * idx)) & 0xFF for idx in range(k * k)]
    return np.array([b - 256 if b > 127 else b for b in raw]).reshape(k, k)


async def start_camera_lcd_top(dut) -> None:
    """Запуск в тестах camera_lcd_top: генератор 50 МГц и PCLK камеры 25 МГц (как XCLK от PLL; у
    OV7670 без делителя PCLK = XCLK), фронты PCLK сдвинуты на задержку проводов и камеры. Кнопка
    отпущена, камера молчит."""
    cocotb.start_soon(Clock(dut.clk50_i, 20, unit="ns").start())
    await Timer(7, unit="ns")
    cocotb.start_soon(Clock(dut.cam_pclk_i, 40, unit="ns").start())
    dut.btn_n_i.value = 1
    dut.cam_vsync_i.value = 0
    dut.cam_href_i.value = 0
    dut.cam_data_i.value = 0


async def capture_screen(
    clk,
    de,
    r,
    g,
    b,
    size: tuple[int, int],
    total: tuple[int, int],
    clk_period_ns: float,
    bits: tuple[int, int, int] = (6, 6, 6),
    timeout_frames: int = 3,
) -> np.ndarray:
    """Один кадр экрана RGB-LCD в режиме DE (сигналы clk, de, r, g, b) — так, как его принимает
    панель: сигналы выбираются по спаду такта дисплея. Экран size = (ширина, высота), полный
    период total = (тактов в строке, строк в кадре). Проверяет интерфейс: RGB и DE не меняются на
    спаде такта, в кадре «высота» строк по «ширина» тактов с DE = 1, период строки и кадра — по
    total. Всё — не дольше timeout_frames кадров. Цвет упакован как в gray_to_rgb() модели."""
    width, height = size
    h_total, v_total = total
    timeout_ns = round(timeout_frames * h_total * v_total * clk_period_ns)
    cycle = 0

    def outputs() -> tuple[int, int, int, int]:
        return int(de.value), int(r.value), int(g.value), int(b.value)

    async def next_sample() -> tuple[int, int, int, int]:
        nonlocal cycle
        await FallingEdge(clk)
        cycle += 1
        sample = outputs()
        await ReadOnly()
        assert outputs() == sample, f"RGB/DE change at the falling clock edge {cycle}"
        return sample

    async def capture() -> np.ndarray:
        # Начало кадра — DE = 1 после паузы длиннее строки (между строками пауза короче).
        idle = 0
        while True:
            de_v, r_v, g_v, b_v = await next_sample()
            if de_v and idle > h_total:
                break
            idle = 0 if de_v else idle + 1
        frame_start = cycle
        line_starts: list[int] = []
        pixels = []
        prev_de = 0
        while True:
            if de_v and not prev_de:  # начало строки
                if len(line_starts) == height:  # первая строка следующего кадра
                    break
                line_starts.append(cycle)
            if de_v:
                pixels.append((r_v << (bits[1] + bits[2])) | (g_v << bits[2]) | b_v)
            if not de_v and prev_de:  # конец строки
                run = cycle - line_starts[-1]
                assert run == width, f"line {len(line_starts) - 1}: DE = 1 for {run} clocks"
            prev_de = de_v
            de_v, r_v, g_v, b_v = await next_sample()
        periods = set(np.diff(line_starts).tolist())
        assert periods == {h_total}, f"line periods {sorted(periods)} clocks, expected {h_total}"
        frame = cycle - frame_start
        assert frame == h_total * v_total, f"frame period {frame}, expected {h_total * v_total}"
        return np.array(pixels, dtype=np.uint32).reshape(height, width)

    return await with_timeout(capture(), timeout_ns, "ns")


async def dvp_camera(
    dut,
    frames: list[np.ndarray],
    h_blank: int = 20,
    v_blank: int = 50,
    vsync_len: int = 10,
    pclk=None,
) -> None:
    """Модель камеры DVP (сигналы PCLK — pclk, по умолчанию dut.pclk_i, — и dut.cam_vsync_i,
    cam_href_i, cam_data_i): для каждого кадра RGB565 — импульс VSYNC, затем строки с HREF,
    пиксель — два байта, старший первым. Данные меняются после фронта PCLK и выбираются ПЛИС
    на следующем фронте."""
    pclk = dut.pclk_i if pclk is None else pclk
    for frame in frames:
        dut.cam_vsync_i.value = 1
        await ClockCycles(pclk, vsync_len)
        dut.cam_vsync_i.value = 0
        await ClockCycles(pclk, v_blank)
        for row in frame:
            dut.cam_href_i.value = 1
            for pixel in row:
                for byte in (int(pixel) >> 8, int(pixel) & 0xFF):
                    dut.cam_data_i.value = byte
                    await RisingEdge(pclk)
            dut.cam_href_i.value = 0
            await ClockCycles(pclk, h_blank)


class SccbMonitor:
    """Декодирует транзакции SCCB. lines() возвращает уровни (SIOC, SIOD) — с учётом открытого
    стока и подтяжки; они выбираются по фронтам clk."""

    def __init__(self, clk, lines) -> None:
        self.clk = clk
        self.lines = lines
        # (такт старта, устройство, регистр, значение)
        self.writes: list[tuple[int, int, int, int]] = []
        self.cycle = 0

    async def run(self) -> None:
        prev_c, prev_d = 1, 1
        bits: list[int] | None = None
        start_cycle = 0
        while True:
            await RisingEdge(self.clk)
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


# Длина строки OV7670 в пикселях (даташит, рис. 6: tLINE = 784 tP); окно HSTART..HSTOP — по кругу.
OV7670_LINE = 784


def ov7670_registers(writes: list[tuple[int, int, int, int]]) -> dict[int, int]:
    """Итоговые значения регистров OV7670 по записям SCCB (последняя запись побеждает)."""
    regs: dict[int, int] = {}
    for _, dev, reg, val in writes:
        assert dev == 0x42, f"write to device {dev:#x}, OV7670 is 0x42"
        regs[reg] = val
    return regs


def check_ov7670_setup(writes: list[tuple[int, int, int, int]]) -> None:
    """Проверяет по даташиту OV7670 (v1.4, таблица 5), что итоговая настройка даёт то, чего
    ждёт dvp_capture: VGA 640×480, RGB565 (не RGB444) с полным диапазоном и первым байтом
    R4..R0 G5..G3 (рис. 11), непрерывный PCLK, VSYNC = 1 в начале кадра (меняется по спаду
    PCLK), HREF = 1 на данных, без масштабирования и деления частоты. Для незаписанных
    регистров — значения после сброса."""
    r = ov7670_registers(writes)
    com7 = r[0x12]
    assert com7 & 0x80 == 0, f"COM7 = {com7:#04x}: the last write must not reset the sensor"
    assert com7 & 0x05 == 0x04, f"COM7 = {com7:#04x}: output must be RGB (bit 2 = 1, bit 0 = 0)"
    assert com7 & 0x38 == 0, f"COM7 = {com7:#04x}: CIF/QVGA/QCIF selected instead of VGA"
    assert com7 & 0x02 == 0, f"COM7 = {com7:#04x}: color bar is on"
    com15 = r.get(0x40, 0xC0)
    assert (com15 >> 4) & 3 == 0b01, f"COM15 = {com15:#04x}: RGB565 needs bits 5:4 = 01"
    assert (com15 >> 6) & 3 == 0b11, f"COM15 = {com15:#04x}: full range 00..FF needs bits 7:6 = 11"
    rgb444 = r.get(0x8C, 0x00)
    assert rgb444 & 0x02 == 0, f"RGB444 = {rgb444:#04x}: RGB444 is on instead of RGB565"
    com10 = r.get(0x15, 0x00)
    assert com10 & 0x20 == 0, f"COM10 = {com10:#04x}: PCLK must run during blanking"
    assert com10 & 0x10 == 0, f"COM10 = {com10:#04x}: PCLK is reversed"
    assert com10 & 0x08 == 0, f"COM10 = {com10:#04x}: HREF is reversed"
    assert com10 & 0x40 == 0, f"COM10 = {com10:#04x}: HREF is replaced by HSYNC"
    assert com10 & 0x02 == 0, f"COM10 = {com10:#04x}: VSYNC is negative"
    # Ограничения входов в .sdc считают, что VSYNC, как и данные, меняется по спаду PCLK.
    assert com10 & 0x04 == 0, f"COM10 = {com10:#04x}: VSYNC changes on the rising edge of PCLK"
    com3 = r.get(0x0C, 0x00)
    assert com3 & 0x40 == 0, f"COM3 = {com3:#04x}: output bytes are swapped"
    assert com3 & 0x0C == 0, f"COM3 = {com3:#04x}: scaling or DCW is on"
    com14 = r.get(0x3E, 0x00)
    assert com14 & 0x10 == 0, f"COM14 = {com14:#04x}: PCLK divider or manual scaling is on"
    clkrc = r.get(0x11, 0x80)
    assert clkrc & 0x3F == 0, f"CLKRC = {clkrc:#04x}: the clock is prescaled"
    # Для RGB565 CLKRC записывается после настроек формата, иначе изображение хуже (драйвер Linux
    # drivers/media/i2c/ov7670.c): COM7, COM15, TSLB, COM13.
    order = [reg for _, _, reg, _ in writes]
    last_clkrc = max(i for i, reg in enumerate(order) if reg == 0x11)
    for reg in (0x12, 0x40, 0x3A, 0x3D):
        if reg in order:
            last = max(i for i, x in enumerate(order) if x == reg)
            assert last < last_clkrc, f"CLKRC is not written again after register {reg:#04x}"
    assert r.get(0x6B, 0x0A) & 0xC0 == 0, "DBLV: the PLL multiplies the clock"
    href, vref = r.get(0x32, 0x80), r.get(0x03, 0x00)
    hstart = r[0x17] << 3 | href & 7
    hstop = r[0x18] << 3 | (href >> 3) & 7
    vstart = r[0x19] << 2 | vref & 3
    vstop = r[0x1A] << 2 | (vref >> 2) & 3
    width = (hstop - hstart) % OV7670_LINE
    assert width == 640, f"HSTART..HSTOP = {hstart}..{hstop}: {width} pixels, expected 640"
    assert vstop - vstart == 480, f"VSTART..VSTOP = {vstart}..{vstop}: expected 480 lines"


def _line(sig) -> int:
    """Уровень линии с открытым стоком и подтяжкой: z (отпущена) — 1."""
    return 0 if str(sig.value) == "0" else 1


async def ov7670_power_up(dut, clk, timeout_ms: int = 200) -> None:
    """Запуск камеры в тестах верхних модулей (порты cam_rst_n_o, cam_pwdn_o, cam_scl_io,
    cam_sda_io; led_n_o[1] = 0 — «камера настроена»). Ждёт аппаратного сброса камеры (RESET# = 0,
    затем 1) при PWDN = 0, декодирует настройку по SCCB (такт clk) до сигнала «камера настроена» и
    проверяет итоговые регистры. Модель камеры выдаёт кадры только после этого — как настоящая,
    которой нужны сброс и настройка. Дальше RESET# и PWDN не должны меняться. Весь запуск — не
    дольше timeout_ms (у ov7670_init при SCCB 25 кГц — около 115 мс)."""
    await with_timeout(_power_up(dut, clk), timeout_ms, "ms")
    cocotb.start_soon(_camera_stays_on(dut))


async def _power_up(dut, clk) -> None:
    monitor = SccbMonitor(clk, lambda: (_line(dut.cam_scl_io), _line(dut.cam_sda_io)))
    task = cocotb.start_soon(monitor.run())
    while dut.cam_rst_n_o.value != 0:
        await dut.cam_rst_n_o.value_change
    assert not monitor.writes, "SCCB writes before the hardware reset of the camera"
    await dut.cam_rst_n_o.value_change
    assert not monitor.writes, "SCCB writes during the hardware reset of the camera"
    assert dut.cam_pwdn_o.value == 0, "the camera is powered down (PWDN = 1)"
    while int(dut.led_n_o.value) & 0b10:
        await First(
            dut.led_n_o.value_change, dut.cam_rst_n_o.value_change, dut.cam_pwdn_o.value_change
        )
        assert dut.cam_rst_n_o.value == 1 and dut.cam_pwdn_o.value == 0, "camera reset during setup"
    task.cancel()
    assert monitor.writes, "the camera is reported configured without SCCB writes"
    check_ov7670_setup(monitor.writes)


async def _camera_stays_on(dut) -> None:
    await First(dut.cam_rst_n_o.value_change, dut.cam_pwdn_o.value_change)
    raise AssertionError("RESET# or PWDN of the camera changed after the setup")
