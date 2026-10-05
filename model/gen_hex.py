"""Генерация файлов инициализации памяти ($readmemh) из модели.

    python3 model/gen_hex.py kernels --k 5 -o kernels.hex
    python3 model/gen_hex.py random --count 78 --seed 1 -o rom.hex

Формат: по одному байту на строку, две шестнадцатеричные цифры.
"""

import argparse
from pathlib import Path

import numpy as np

from svconv_model import kernel_rom_bytes


def write_hex(path: Path, data: list[int]) -> None:
    path.write_text("".join(f"{b:02x}\n" for b in data))


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate $readmemh memory init files from the model.")
    sub = parser.add_subparsers(dest="what", required=True)

    kernels = sub.add_parser("kernels", help="convolution kernel ROM")
    kernels.add_argument("--k", type=int, required=True, help="stage window size")
    kernels.add_argument("-o", "--output", type=Path, required=True)

    rand = sub.add_parser("random", help="random bytes (e.g. ROM contents for formal checks)")
    rand.add_argument("--count", type=int, required=True)
    rand.add_argument("--seed", type=int, default=1)
    rand.add_argument("-o", "--output", type=Path, required=True)

    args = parser.parse_args()
    if args.what == "kernels":
        write_hex(args.output, kernel_rom_bytes(args.k))
    else:
        rng = np.random.default_rng(args.seed)
        write_hex(args.output, [int(v) for v in rng.integers(0, 256, args.count)])


if __name__ == "__main__":
    main()
