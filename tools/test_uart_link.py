"""Тесты resync() (uart_link.py): клиент восстанавливает обмен с платой после прерванного запуска.

Плата имитируется на псевдотерминале: настоящий pyserial с одной стороны, модель автомата
команд стендов (rtl/bench/uart_bench.sv и camera_uart.sv: тайм-аут незавершённой 'c', проверка
номеров ядер, команды игнорируются, пока идёт ответ; у camera_uart — ожидание кадра камеры,
которое отменяет любой байт) — с другой.
"""

import os
import pty
import select
import threading
import time
import tty

import pytest
import serial

import uart_link

# Тайм-аут незавершённой команды стенда: CmdTimeoutBits = 1000 бит на 115200 бод.
CMD_TIMEOUT_S = 1000 / 115_200
NUM_KERNELS = 3


class FakeBench:
    """Модель стенда uart_bench: 'c' en sel, 'p' — 4 байта периода, 'f' — кадр (здесь 64 байта
    с номером конфигурации). Начальное состояние задаёт сценарий прерванного запуска."""

    FRAME_BYTES = 64
    PERIOD = 19200

    def __init__(self, start_state: str = "idle", leftover: int = 0) -> None:
        self.master, slave = pty.openpty()
        tty.setraw(slave)
        self.port_name = os.ttyname(slave)
        self.state = start_state
        self.leftover = leftover  # хвост старого ответа, который плата ещё досылает
        self.en, self.sel = 0b111, 0
        self.pending_en = 0
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _read(self, timeout: float) -> int | None:
        ready, _, _ = select.select([self.master], [], [], timeout)
        return os.read(self.master, 1)[0] if ready else None

    def _run(self) -> None:
        # Пока досылается хвост старого ответа, входящие байты игнорируются.
        while self.leftover > 0 and not self.stop.is_set():
            chunk = min(self.leftover, 256)
            os.write(self.master, b"\x55" * chunk)
            self.leftover -= chunk
            while self._read(0) is not None:
                pass
            time.sleep(256 * 10 / 115_200)
        while not self.stop.is_set():
            in_cmd = self.state in ("cfg_en", "cfg_sel")
            byte = self._read(CMD_TIMEOUT_S if in_cmd else 0.05)
            if byte is None:
                if in_cmd:
                    self.state = "idle"  # команда оборвалась
                continue
            if self.state == "wait_frame":
                self.state = "idle"  # camera_uart: любой байт отменяет ожидание кадра камеры
            elif self.state == "idle":
                if byte == ord("c"):
                    self.state = "cfg_en"
                elif byte == ord("p"):
                    os.write(self.master, self.PERIOD.to_bytes(4, "little"))
                elif byte == ord("f"):
                    os.write(self.master, bytes([self.en, self.sel]) * (self.FRAME_BYTES // 2))
            elif self.state == "cfg_en":
                self.pending_en = byte & 0b111
                self.state = "cfg_sel"
            elif self.state == "cfg_sel":
                if all((byte >> (2 * s)) & 0b11 < NUM_KERNELS for s in range(3)):
                    self.en, self.sel = self.pending_en, byte & 0x3F
                self.state = "idle"

    def close(self) -> None:
        self.stop.set()
        self.thread.join(1)
        os.close(self.master)


@pytest.fixture
def bench_factory():
    benches = []

    def make(**kwargs) -> FakeBench:
        bench = FakeBench(**kwargs)
        benches.append(bench)
        return bench

    yield make
    for bench in benches:
        bench.close()


def exchange(port: serial.Serial) -> tuple[int, bytes]:
    """То, что делает клиент после resync(): настройка, кадр, период."""
    port.write(bytes([ord("c"), 0b101, (2 << 4) | 1]))
    port.write(b"f")
    frame = port.read(FakeBench.FRAME_BYTES)
    port.write(b"p")
    period = int.from_bytes(port.read(4), "little")
    return period, frame


@pytest.mark.parametrize(
    "scenario",
    [
        {},  # обычный запуск
        {"leftover": 4000},  # плата досылает хвост прерванной выгрузки
        {"start_state": "cfg_en"},  # прерван посреди 'c': ждёт байт en
        {"start_state": "cfg_sel"},  # прерван посреди 'c': ждёт байт sel
        {"start_state": "wait_frame"},  # camera_uart: камера не работала, ждёт кадр
    ],
    ids=["idle", "leftover", "after_c", "after_c_en", "camera_wait"],
)
def test_resync_restores_exchange(bench_factory, scenario):
    bench = bench_factory(**scenario)
    with serial.Serial(bench.port_name, 115_200, timeout=2) as port:
        uart_link.resync(port)
        assert port.timeout == 2, "resync() must restore the port timeout"
        period, frame = exchange(port)
    assert period == FakeBench.PERIOD
    assert frame == bytes([0b101, (2 << 4) | 1]) * (FakeBench.FRAME_BYTES // 2)


def test_without_resync_leftover_breaks_exchange(bench_factory):
    """Проверка самой имитации: без resync() хвост старого ответа ломает обмен."""
    bench = bench_factory(leftover=4000)
    with serial.Serial(bench.port_name, 115_200, timeout=0.5) as port:
        port.reset_input_buffer()
        _, frame = exchange(port)
    assert frame != bytes([0b101, (2 << 4) | 1]) * (FakeBench.FRAME_BYTES // 2)


def test_resync_gives_up_if_board_keeps_sending(bench_factory, monkeypatch):
    monkeypatch.setattr(uart_link, "MAX_DRAIN_S", 0.3)
    bench = bench_factory(leftover=10**9)
    with serial.Serial(bench.port_name, 115_200, timeout=2) as port:
        with pytest.raises(SystemExit):
            uart_link.resync(port)
        assert port.timeout == 2, "resync() must restore the port timeout on failure"
