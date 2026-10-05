"""Клиент стенда camera_uart: забирает с платы кадр камеры (серый, 160×120) и результат цепочки
свёрток для этого же кадра, сохраняет их картинками и сверяет результат с моделью.

    python3 tools/camera_uart.py /dev/ttyUSB1 --chain gauss5,gauss5,log5 --out out/
    python3 tools/camera_uart.py /dev/ttyUSB1 --chain=-,-,- --out out/   # без обработки

Значение, начинающееся с '-', передаётся через '=' (--chain=-,...), иначе argparse принимает
его за ключ.

Протокол — см. rtl/bench/camera_uart.sv.
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import serial
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "model"))

from svconv_model import KERNEL_ROM_ORDER, KERNELS, pad_kernel, pipeline  # noqa: E402
from uart_link import resync  # noqa: E402

WIDTH, HEIGHT, K, NUM_STAGES = 160, 120, 5, 3
CLK_FREQ = 27_000_000
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


def check(out: np.ndarray, expected: np.ndarray, period: int) -> list[str]:
    """Сверяет результат с моделью, применённой к серому кадру с платы; возвращает список
    расхождений (пустой — всё верно). Период кадров камеры известен, раз кадр захвачен."""
    problems = []
    mismatches = int((out != expected).sum())
    if mismatches:
        problems.append(f"{mismatches} of {out.size} result pixels differ from the model")
    if period == 0:
        problems.append("camera frame period is 0 although a frame was captured")
    return problems


def read_exact(port: serial.Serial, count: int) -> bytes:
    data = port.read(count)
    if len(data) != count:
        raise SystemExit(f"timeout: received {len(data)} of {count} bytes")
    return data


def save(img: np.ndarray, path: Path) -> None:
    """Сохраняет кадр, увеличенный в 4 раза, чтобы его было удобно рассматривать."""
    Image.fromarray(img).resize((WIDTH * 4, HEIGHT * 4), Image.NEAREST).save(path)


def main() -> None:
    parser = argparse.ArgumentParser(description="Capture a camera frame and its result via UART.")
    parser.add_argument("port", help="serial port of the BL702 debugger, e.g. /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115_200)
    parser.add_argument(
        "--chain",
        default="gauss5,gauss5,log5",
        help="kernels of the 3 stages, '-' = bypass (use --chain=-,... if it starts with '-')",
    )
    parser.add_argument("--out", type=Path, help="directory to save images")
    args = parser.parse_args()

    kernels, enabled = parse_chain(args.chain)
    en = sum(int(e) << s for s, e in enumerate(enabled))
    sel = sum(KERNEL_ROM_ORDER.index(n) << (s * SEL_W) for s, n in enumerate(kernels))

    # Два кадра по 19200 байт на 115200 бод идут ~3,4 с; ждём с запасом.
    with serial.Serial(args.port, args.baud, timeout=10) as port:
        resync(port)
        port.write(bytes([ord("c"), en, sel]))
        start = time.monotonic()
        port.write(b"f")
        data = port.read(2 * WIDTH * HEIGHT)
        if len(data) != 2 * WIDTH * HEIGHT:
            port.write(b"x")  # отменить ожидание кадра на плате
            raise SystemExit(
                f"timeout: received {len(data)} bytes; is the camera running (LED4 blinking)?"
            )
        elapsed = time.monotonic() - start
        # Период — после захвата: к этому времени камера выдала не меньше двух кадров.
        port.write(b"p")
        period = int.from_bytes(read_exact(port, 4), "little")

    raw = np.frombuffer(data[: WIDTH * HEIGHT], dtype=np.uint8).reshape(HEIGHT, WIDTH)
    out = np.frombuffer(data[WIDTH * HEIGHT :], dtype=np.uint8).reshape(HEIGHT, WIDTH)
    chain = [pad_kernel(KERNELS[n], K) for n, e in zip(kernels, enabled) if e]
    expected = pipeline(raw, chain)
    problems = check(out, expected, period)

    print(f"chain: {args.chain}")
    if period:
        print(f"camera frame period: {period} cycles of 27 MHz ({CLK_FREQ / period:.2f} fps)")
    print(f"frames received in {elapsed:.2f} s")
    print(f"mismatches of the result with the model: {int((out != expected).sum())} of {out.size}")
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        save(raw, args.out / "camera_gray.png")
        save(out, args.out / "result.png")
        save(expected, args.out / "expected.png")
        print(f"images saved to {args.out}")
    for problem in problems:
        print(f"FAIL: {problem}")
    if not problems:
        print("PASS")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
