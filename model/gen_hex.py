"""Генерация файлов инициализации памяти ($readmemh) из модели.

    python3 model/gen_hex.py kernels --k 5 -o kernels.hex
    python3 model/gen_hex.py image photo.png --size 160x120 -o image.hex
    python3 model/gen_hex.py random --count 78 --seed 1 -o rom.hex

Формат: по одному байту на строку, две шестнадцатеричные цифры.
"""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

from svconv_model import kernel_rom_bytes, rgb888_to_gray


def write_hex(path: Path, data: list[int]) -> None:
    path.write_text("".join(f"{b:02x}\n" for b in data))


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate $readmemh memory init files from the model.")
    sub = parser.add_subparsers(dest="what", required=True)

    kernels = sub.add_parser("kernels", help="convolution kernel ROM")
    kernels.add_argument("--k", type=int, required=True, help="stage window size")
    kernels.add_argument("-o", "--output", type=Path, required=True)

    image = sub.add_parser("image", help="grayscale image, row by row")
    image.add_argument("input", type=Path)
    image.add_argument("--size", default="160x120", help="width x height")
    image.add_argument("-o", "--output", type=Path, required=True)

    rand = sub.add_parser("random", help="random bytes (e.g. ROM contents for formal checks)")
    rand.add_argument("--count", type=int, required=True)
    rand.add_argument("--seed", type=int, default=1)
    rand.add_argument("-o", "--output", type=Path, required=True)

    args = parser.parse_args()
    if args.what == "kernels":
        write_hex(args.output, kernel_rom_bytes(args.k))
    elif args.what == "random":
        rng = np.random.default_rng(args.seed)
        write_hex(args.output, [int(v) for v in rng.integers(0, 256, args.count)])
    else:
        w, h = (int(v) for v in args.size.split("x"))
        rgb = np.asarray(Image.open(args.input).convert("RGB").resize((w, h)))
        write_hex(args.output, [int(v) for v in rgb888_to_gray(rgb).flatten()])


if __name__ == "__main__":
    main()
