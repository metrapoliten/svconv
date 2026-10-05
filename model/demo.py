"""Демонстрация модели на настоящем изображении.

    python3 model/demo.py photo.jpg out/ --size 640x480 --chain gauss5,gauss5,log5

Сохраняет в out/: 00_gray.png и по файлу на каждый каскад цепочки.
"""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

from svconv_model import KERNELS, convolve, rgb888_to_gray


def main() -> None:
    parser = argparse.ArgumentParser(description="Apply a kernel chain of the model to an image.")
    parser.add_argument("image", type=Path)
    parser.add_argument("out_dir", type=Path)
    parser.add_argument("--size", default="640x480", help="processing width x height")
    parser.add_argument(
        "--chain",
        default="gauss5,gauss5,log5",
        help=f"comma-separated kernels, available: {', '.join(KERNELS)}",
    )
    args = parser.parse_args()

    w, h = (int(v) for v in args.size.split("x"))
    rgb = np.asarray(Image.open(args.image).convert("RGB").resize((w, h)))
    img = rgb888_to_gray(rgb)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    Image.fromarray(img).save(args.out_dir / "00_gray.png")
    for i, name in enumerate(args.chain.split(","), start=1):
        img = convolve(img, KERNELS[name])
        Image.fromarray(img).save(args.out_dir / f"{i:02d}_{name}.png")


if __name__ == "__main__":
    main()
