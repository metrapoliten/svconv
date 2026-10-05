"""Помощник фокусировки камеры для стенда camera_uart: раз в несколько секунд забирает с платы
кадр и его результат и перезаписывает одну картинку (слева серый кадр, справа результат
цепочки), а в терминале печатает число резкости. Картинку удобно держать открытой в VS Code —
он обновляет её сам. Поворачивайте объектив, пока число растёт: максимум — это фокус.

    python3 tools/camera_focus.py /dev/ttyUSB1
    python3 tools/camera_focus.py /dev/ttyUSB1 --image /tmp/out/focus.png

Остановка — Ctrl+C. Протокол — см. rtl/bench/camera_uart.sv.
"""

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import serial
from PIL import Image

from camera_uart import HEIGHT, KERNEL_ROM_ORDER, SEL_W, WIDTH, parse_chain
from uart_link import resync

SCALE = 3  # во сколько раз увеличить картинку
BAR = 40  # длина полоски резкости в терминале


def sharpness(gray: np.ndarray) -> float:
    """Резкость кадра: дисперсия лапласиана (сумма вторых разностей по строке и столбцу). У
    размытого кадра соседние пиксели близки, и лапласиан мал; в фокусе края резкие."""
    g = gray.astype(np.int32)
    lap = 4 * g[1:-1, 1:-1] - g[:-2, 1:-1] - g[2:, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]
    return float(lap.var())


def side_by_side(gray: np.ndarray, out: np.ndarray) -> np.ndarray:
    """Серый кадр и результат рядом через светлую полоску, увеличенные в SCALE раз."""
    gap = np.full((gray.shape[0], 2), 255, dtype=np.uint8)
    both = np.hstack([gray, gap, out])
    return np.kron(both, np.ones((SCALE, SCALE), dtype=np.uint8))


def save_atomic(img: np.ndarray, path: Path) -> None:
    """Пишет картинку во временный файл и переименовывает: просмотрщик не увидит полфайла."""
    tmp = path.with_name(path.name + ".tmp.png")
    Image.fromarray(img).save(tmp)
    os.replace(tmp, path)


def main() -> None:
    parser = argparse.ArgumentParser(description="Live camera focus helper for camera_uart.")
    parser.add_argument("port", help="serial port of the BL702 debugger, e.g. /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115_200)
    parser.add_argument(
        "--chain",
        default="gauss5,gauss5,log5",
        help="kernels of the 3 stages, '-' = bypass (use --chain=-,... if it starts with '-')",
    )
    parser.add_argument("--image", type=Path, default=Path("/tmp/out/focus.png"))
    args = parser.parse_args()

    kernels, enabled = parse_chain(args.chain)
    en = sum(int(e) << s for s, e in enumerate(enabled))
    sel = sum(KERNEL_ROM_ORDER.index(n) << (s * SEL_W) for s, n in enumerate(kernels))
    args.image.parent.mkdir(parents=True, exist_ok=True)
    print(f"updating {args.image} (open it in an image viewer); Ctrl+C to stop")

    best = 0.0
    with serial.Serial(args.port, args.baud, timeout=10) as port:
        resync(port)
        port.write(bytes([ord("c"), en, sel]))
        try:
            while True:
                port.write(b"f")
                data = port.read(2 * WIDTH * HEIGHT)
                if len(data) != 2 * WIDTH * HEIGHT:
                    port.write(b"x")  # отменить ожидание кадра на плате
                    print(f"timeout: received {len(data)} bytes; is the camera running?")
                    resync(port)
                    continue
                gray = np.frombuffer(data[: WIDTH * HEIGHT], dtype=np.uint8).reshape(HEIGHT, WIDTH)
                out = np.frombuffer(data[WIDTH * HEIGHT :], dtype=np.uint8).reshape(HEIGHT, WIDTH)
                save_atomic(side_by_side(gray, out), args.image)
                value = sharpness(gray)
                best = max(best, value)
                bar = "#" * round(BAR * value / best) if best else ""
                print(f"sharpness {value:8.1f}   best {best:8.1f}   {bar}", flush=True)
        except KeyboardInterrupt:
            print()
    sys.exit(0)


if __name__ == "__main__":
    main()
