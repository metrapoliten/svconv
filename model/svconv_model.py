"""Эталонная модель конвейера обработки изображений.

Модель — это спецификация: RTL обязан выдавать ровно те же числа (побитовое совпадение).
Поэтому все вычисления целочисленные, а правила округления, насыщения и обработки краёв
заданы явно.

Конвейер: RGB565 с камеры -> RGB888 -> оттенки серого (8 бит) -> цепочка свёрток.

Свёртка (как в приложении курса «Свёртка изображений») — это корреляция без отражения ядра:

    acc[r, c] = sum_{i,j} img[r + i - p, c + j - p] * w[i, j],   p = K // 2

Постобработка накопленной суммы acc:
    mode="clamp": y = clamp(round(acc / 2^shift), 0, 255)    — размытие и т. п.
    mode="abs":   y = clamp(round(|acc| / 2^shift), 0, 255)  — выделение границ
где round — округление половины вверх: (x + 2^(shift-1)) >> shift.

Края: пиксели, для которых окно K×K выходит за границу изображения (по p строк и столбцов
с каждой стороны), равны 0.
"""

from dataclasses import dataclass

import numpy as np

# Разрядность весов ядра в аппаратуре: знаковые 8 бит.
WEIGHT_MIN, WEIGHT_MAX = -128, 127


@dataclass(frozen=True)
class Kernel:
    """Ядро свёртки: целые веса K×K, нормирующий сдвиг и режим постобработки."""

    name: str
    weights: np.ndarray  # K×K, целые
    shift: int  # сумма делится на 2^shift
    mode: str  # "clamp" или "abs"

    def __post_init__(self) -> None:
        w = np.asarray(self.weights)
        k = w.shape[0]
        if w.ndim != 2 or w.shape != (k, k) or k % 2 == 0:
            raise ValueError(f"{self.name}: kernel must be square with an odd size")
        if w.min() < WEIGHT_MIN or w.max() > WEIGHT_MAX:
            raise ValueError(f"{self.name}: weights do not fit into signed 8 bits")
        if self.shift < 0:
            raise ValueError(f"{self.name}: shift must be non-negative")
        if self.mode not in ("clamp", "abs"):
            raise ValueError(f"{self.name}: unknown mode {self.mode}")

    @property
    def size(self) -> int:
        return self.weights.shape[0]


def _binomial(k: int) -> np.ndarray:
    """Двумерное биномиальное ядро k×k (приближение гауссова), сумма весов 4^(k-1)."""
    row = np.array([1], dtype=np.int64)
    for _ in range(k - 1):
        row = np.convolve(row, [1, 1])
    return np.outer(row, row)


# Набор ядер: размытие и выделение границ 5×5 из задания и тождественное ядро 3×3
# (выход равен входу — для проверки конвейера).
# Сдвиги подобраны так, чтобы результат не выходил за 0..255:
# у размытий сумма весов равна 2^shift, у детекторов границ максимум |acc| не больше 255·2^shift.
KERNELS = {
    k.name: k
    for k in [
        Kernel("identity", np.array([[0, 0, 0], [0, 1, 0], [0, 0, 0]]), shift=0, mode="clamp"),
        Kernel("gauss5", _binomial(5), shift=8, mode="clamp"),
        Kernel(
            "log5",  # лапласиан гауссиана 5×5
            np.array(
                [
                    [0, 0, -1, 0, 0],
                    [0, -1, -2, -1, 0],
                    [-1, -2, 16, -2, -1],
                    [0, -1, -2, -1, 0],
                    [0, 0, -1, 0, 0],
                ]
            ),
            shift=4,
            mode="abs",
        ),
    ]
}


# Порядок ядер в аппаратном ПЗУ: номер ядра (вход kernel_sel) — индекс в этом списке.
KERNEL_ROM_ORDER = ["identity", "gauss5", "log5"]


def pad_kernel(kernel: Kernel, k: int) -> Kernel:
    """Дополняет ядро нулями до k×k: аппаратный каскад всегда работает с окном k×k,
    поэтому и обнуляемая рамка у него шириной k // 2, а не kernel.size // 2."""
    if kernel.size > k:
        raise ValueError(f"{kernel.name}: kernel {kernel.size}x{kernel.size} is larger than window {k}x{k}")
    pad = (k - kernel.size) // 2
    return Kernel(kernel.name, np.pad(kernel.weights, pad), kernel.shift, kernel.mode)


def kernel_rom_bytes(k: int) -> list[int]:
    """Содержимое ПЗУ ядер для каскада с окном k×k, по байту на ячейку.

    Запись ядра — k*k + 1 байт: веса построчно (дополнительный код), затем байт настройки
    {abs, 0, 0, 0, shift[3:0]}. Ядра идут в порядке KERNEL_ROM_ORDER.
    """
    rom = []
    for name in KERNEL_ROM_ORDER:
        kernel = pad_kernel(KERNELS[name], k)
        if kernel.shift > 15:
            raise ValueError(f"{name}: shift does not fit into 4 bits")
        rom += [int(w) & 0xFF for w in kernel.weights.flatten()]
        rom.append((0x80 if kernel.mode == "abs" else 0) | kernel.shift)
    return rom


def sample_image(width: int, height: int) -> np.ndarray:
    """Детерминированное тестовое изображение в оттенках серого (uint8, height×width):
    диагональный градиент, светлый прямоугольник, тёмный круг и тонкие линии — на нём
    хорошо видны и размытие, и выделение границ. Масштабируется под любой размер кадра."""
    y, x = np.mgrid[0:height, 0:width]
    img = (x * 160 // max(width - 1, 1) + y * 95 // max(height - 1, 1)).astype(np.int64)
    rect = (x >= width // 8) & (x < width * 3 // 8) & (y >= height // 4) & (y < height * 3 // 4)
    img[rect] = 240
    cx, cy, r = width * 5 // 8, height // 2, min(width, height) // 4
    img[(x - cx) ** 2 + (y - cy) ** 2 < r * r] = 30
    img[:, width * 7 // 8] = 255
    img[height * 7 // 8, :] = 0
    return np.clip(img, 0, 255).astype(np.uint8)


def decimate(img: np.ndarray, factor: int, out_width: int, out_height: int) -> np.ndarray:
    """Прореживание как в frame_decimator: из каждого квадрата factor×factor — левый верхний
    пиксель, область out_width×out_height от левого верхнего угла."""
    small = np.asarray(img)[::factor, ::factor][:out_height, :out_width]
    if small.shape[:2] != (out_height, out_width):
        raise ValueError(f"image is too small for {out_width}x{out_height} after decimation")
    return small


def rgb565_to_rgb888(pix: np.ndarray) -> np.ndarray:
    """RGB565 (uint16, H×W) -> RGB888 (uint8, H×W×3).

    Младшие биты заполняются старшими (R5 -> R5<<3 | R5>>2), так что 0x1F переходит в 0xFF.
    """
    pix = np.asarray(pix, dtype=np.uint32)
    r5 = (pix >> 11) & 0x1F
    g6 = (pix >> 5) & 0x3F
    b5 = pix & 0x1F
    r = (r5 << 3) | (r5 >> 2)
    g = (g6 << 2) | (g6 >> 4)
    b = (b5 << 3) | (b5 >> 2)
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


def rgb888_to_gray(rgb: np.ndarray) -> np.ndarray:
    """RGB888 (H×W×3) -> оттенки серого (uint8), как в курсе: (77R + 150G + 29B) >> 8."""
    rgb = np.asarray(rgb, dtype=np.uint32)
    y = (77 * rgb[..., 0] + 150 * rgb[..., 1] + 29 * rgb[..., 2]) >> 8
    return y.astype(np.uint8)


def conv1d_valid(row: np.ndarray, w: np.ndarray) -> np.ndarray:
    """Одномерная свёртка (корреляция) строки с ядром длины K без выхода за границы.

    Возвращает len(row) - K + 1 значений: out[c] = sum_j row[c + j] * w[j].
    """
    k = len(w)
    n = len(row) - k + 1
    out = np.zeros(n, dtype=np.int64)
    for j in range(k):
        out += row[j : j + n].astype(np.int64) * int(w[j])
    return out


def conv2d_acc(img: np.ndarray, w: np.ndarray) -> np.ndarray:
    """Накопленные суммы acc для внутренних пикселей (H-K+1)×(W-K+1).

    Двумерная свёртка раскладывается на одномерные, как в схеме курса: строка результата —
    это сумма одномерных свёрток K соседних строк изображения с соответствующими строками ядра.
    """
    img = np.asarray(img)
    k = w.shape[0]
    h = img.shape[0]
    rows = []
    for r in range(h - k + 1):
        rows.append(sum(conv1d_valid(img[r + i], w[i]) for i in range(k)))
    return np.array(rows, dtype=np.int64)


def postprocess(acc: np.ndarray, shift: int, mode: str) -> np.ndarray:
    """Нормировка, округление половины вверх и насыщение до 0..255."""
    if mode == "abs":
        acc = np.abs(acc)
    if shift > 0:
        acc = (acc + (1 << (shift - 1))) >> shift
    return np.clip(acc, 0, 255).astype(np.uint8)


def convolve(img: np.ndarray, kernel: Kernel) -> np.ndarray:
    """Свёртка изображения uint8 ядром kernel; края (по K//2 с каждой стороны) равны 0."""
    img = np.asarray(img, dtype=np.uint8)
    p = kernel.size // 2
    out = np.zeros_like(img)
    inner = postprocess(conv2d_acc(img, kernel.weights), kernel.shift, kernel.mode)
    out[p : img.shape[0] - p, p : img.shape[1] - p] = inner
    return out


def pipeline(img: np.ndarray, kernels: list[Kernel]) -> np.ndarray:
    """Последовательное применение цепочки свёрток (каскадов)."""
    for kernel in kernels:
        img = convolve(img, kernel)
    return img


def gray_to_rgb565(img: np.ndarray) -> np.ndarray:
    """Оттенки серого (uint8) -> RGB565 (uint16) с R = G = B, как на выходе lcd_frame_reader."""
    g = np.asarray(img, dtype=np.uint16)
    return ((g >> 3) << 11) | ((g >> 2) << 5) | (g >> 3)


def display_frame(img: np.ndarray, width: int, height: int, scale: int) -> np.ndarray:
    """Что видно на экране width×height (RGB565): img, увеличенное в scale раз повторением
    пикселей и размещённое по центру (смещения округляются вниз), вокруг — чёрный."""
    big = np.kron(np.asarray(img, dtype=np.uint8), np.ones((scale, scale), dtype=np.uint8))
    h, w = big.shape
    if w > width or h > height:
        raise ValueError(f"scaled image {w}x{h} does not fit the display {width}x{height}")
    screen = np.zeros((height, width), dtype=np.uint16)
    off_x, off_y = (width - w) // 2, (height - h) // 2
    screen[off_y : off_y + h, off_x : off_x + w] = gray_to_rgb565(big)
    return screen
