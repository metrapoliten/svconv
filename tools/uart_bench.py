"""Клиент стенда uart_bench: настраивает цепочку свёрток на плате, забирает кадр и сверяет
его с эталонной моделью.

    python3 tools/uart_bench.py /dev/ttyUSB1 --chain gauss5,gauss5,log5 --out out/
    python3 tools/uart_bench.py /dev/ttyUSB1 --chain gauss5,-,log5     # '-' — каскад выключен

Протокол — см. rtl/bench/uart_bench.sv.
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import serial
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "model"))

from svconv_model import (  # noqa: E402
    KERNEL_ROM_ORDER,
    KERNELS,
    pad_kernel,
    pipeline,
    sample_image,
)
from uart_link import resync  # noqa: E402

WIDTH, HEIGHT, K, NUM_STAGES = 160, 120, 5, 3
# Генератор стенда выдаёт пиксель каждый такт без гашения, поэтому кадр идёт ровно W*H тактов.
EXPECTED_PERIOD = WIDTH * HEIGHT
SEL_W = max(1, (len(KERNEL_ROM_ORDER) - 1).bit_length())


def parse_chain(text: str) -> tuple[list[str], list[bool]]:
    """'gauss5,-,log5' -> (['gauss5', 'identity', 'log5'], [True, False, True])."""
    names = text.split(",")
    if len(names) != NUM_STAGES:
        raise SystemExit(f"--chain must list {NUM_STAGES} stages, got {len(names)}")
    kernels, enabled = [], []
    for name in names:
        if name == "-":
            kernels.append("identity")
            enabled.append(False)
        elif name in KERNEL_ROM_ORDER:
            kernels.append(name)
            enabled.append(True)
        else:
            raise SystemExit(f"unknown kernel {name!r}, available: {', '.join(KERNEL_ROM_ORDER)}")
    return kernels, enabled


def check(frame: np.ndarray, expected: np.ndarray, period: int) -> list[str]:
    """Сверяет результат с ожидаемым; возвращает список расхождений (пустой — всё верно)."""
    problems = []
    mismatches = int((frame != expected).sum())
    if mismatches:
        problems.append(f"{mismatches} of {frame.size} pixels differ from the model")
    if period != EXPECTED_PERIOD:
        problems.append(f"frame period is {period} cycles, expected {EXPECTED_PERIOD}")
    return problems


def read_exact(port: serial.Serial, count: int) -> bytes:
    data = port.read(count)
    if len(data) != count:
        raise SystemExit(f"timeout: received {len(data)} of {count} bytes")
    return data


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the convolution chain on the board via UART.")
    parser.add_argument("port", help="serial port of the BL702 debugger, e.g. /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115_200)
    parser.add_argument(
        "--chain",
        default="gauss5,gauss5,log5",
        help="kernels of the 3 stages, '-' = bypass (use --chain=-,... if it starts with '-')",
    )
    parser.add_argument("--out", type=Path, help="directory to save received/expected images")
    args = parser.parse_args()

    kernels, enabled = parse_chain(args.chain)
    en = sum(int(e) << s for s, e in enumerate(enabled))
    sel = sum(KERNEL_ROM_ORDER.index(n) << (s * SEL_W) for s, n in enumerate(kernels))

    # Кадр 19200 байт на 115200 бод идёт ~1,7 с.
    with serial.Serial(args.port, args.baud, timeout=5) as port:
        resync(port)
        port.write(bytes([ord("c"), en, sel]))
        start = time.monotonic()
        port.write(b"f")
        frame = np.frombuffer(read_exact(port, WIDTH * HEIGHT), dtype=np.uint8)
        elapsed = time.monotonic() - start
        port.write(b"p")
        period = int.from_bytes(read_exact(port, 4), "little")

    frame = frame.reshape(HEIGHT, WIDTH)
    chain = [pad_kernel(KERNELS[n], K) for n, e in zip(kernels, enabled) if e]
    expected = pipeline(sample_image(WIDTH, HEIGHT), chain)
    problems = check(frame, expected, period)

    print(f"chain: {args.chain}")
    print(f"frame received in {elapsed:.2f} s")
    print(f"frame period: {period} cycles ({period / (WIDTH * HEIGHT):.3f} cycles per pixel)")
    print(f"mismatches with the model: {int((frame != expected).sum())} of {WIDTH * HEIGHT}")
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        Image.fromarray(frame).save(args.out / "received.png")
        Image.fromarray(expected).save(args.out / "expected.png")
        print(f"images saved to {args.out}")
    for problem in problems:
        print(f"FAIL: {problem}")
    if not problems:
        print("PASS")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
