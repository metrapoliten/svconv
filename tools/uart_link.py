"""Общая часть клиентов стендов (uart_bench.py, camera_uart.py): восстановление обмена с платой.

Если прошлый запуск клиента прервали, плата может быть посреди обмена: допередавать кадр,
ждать кадр камеры или оставшийся байт команды 'c'. Очистка буфера компьютера этого не
исправляет, поэтому перед командами клиент вызывает resync().
"""

import time

import serial

# Байт, безопасный в любом состоянии стенда: в ожидании команды — неизвестная команда
# (игнорируется), в ожидании кадра камеры — отмена, вместо байта настройки — несуществующие
# номера ядер (команда отбрасывается).
RESYNC_BYTE = 0xFF
# Тишина на линии дольше тайм-аута незавершённой команды стенда (1000 бит, ~8,7 мс на 115200).
QUIET_S = 0.05
# Самый длинный ответ — два кадра camera_uart, ~3,4 с на 115200.
MAX_DRAIN_S = 8.0


def resync(port: serial.Serial) -> None:
    """Возвращает стенд в ожидание команд: отменяет ожидание кадра, дочитывает то, что плата
    ещё передаёт, и выжидает тишину на линии."""
    saved_timeout = port.timeout
    port.write(bytes([RESYNC_BYTE]))
    port.timeout = QUIET_S
    deadline = time.monotonic() + MAX_DRAIN_S
    try:
        while port.read(4096):
            if time.monotonic() > deadline:
                raise SystemExit("the board keeps sending data; reload the bitstream")
    finally:
        port.timeout = saved_timeout
