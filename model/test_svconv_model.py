"""Тесты эталонной модели: сверка с независимой реализацией из scipy и проверка свойств."""

import numpy as np
import pytest
from scipy import ndimage

from svconv_model import (
    KERNEL_ROM_ORDER,
    KERNELS,
    Kernel,
    conv2d_acc,
    convolve,
    decimate,
    display_frame,
    gray_to_rgb,
    kernel_rom_bytes,
    pad_kernel,
    pipeline,
    postprocess,
    rgb565_to_rgb888,
    rgb888_to_gray,
    sample_image,
)

RNG = np.random.default_rng(2026)


def random_image(h: int = 24, w: int = 32) -> np.ndarray:
    return RNG.integers(0, 256, size=(h, w), dtype=np.uint8)


@pytest.mark.parametrize("name", list(KERNELS))
def test_acc_matches_scipy(name: str) -> None:
    """Разложение на одномерные свёртки даёт то же, что двумерная корреляция scipy."""
    kernel = KERNELS[name]
    img = random_image()
    p = kernel.size // 2
    expected = ndimage.correlate(img.astype(np.int64), kernel.weights.astype(np.int64))
    expected = expected[p : img.shape[0] - p, p : img.shape[1] - p]
    np.testing.assert_array_equal(conv2d_acc(img, kernel.weights), expected)


@pytest.mark.parametrize("name", list(KERNELS))
def test_borders_are_zero(name: str) -> None:
    kernel = KERNELS[name]
    p = kernel.size // 2
    out = convolve(np.full((16, 16), 200, dtype=np.uint8), kernel)
    assert not out[:p].any() and not out[-p:].any()
    assert not out[:, :p].any() and not out[:, -p:].any()


def test_identity_keeps_inner_pixels() -> None:
    img = random_image()
    out = convolve(img, KERNELS["identity"])
    np.testing.assert_array_equal(out[1:-1, 1:-1], img[1:-1, 1:-1])


@pytest.mark.parametrize("value", [0, 1, 128, 255])
def test_blur_keeps_constant_image(value: int) -> None:
    """Сумма весов размытия равна 2^shift, поэтому однотонная картинка не меняется."""
    kernel = KERNELS["gauss5"]
    p = kernel.size // 2
    out = convolve(np.full((12, 12), value, dtype=np.uint8), kernel)
    assert (out[p:-p, p:-p] == value).all()


def test_edge_detector_zero_on_constant_image() -> None:
    kernel = KERNELS["log5"]
    p = kernel.size // 2
    out = convolve(np.full((12, 12), 77, dtype=np.uint8), kernel)
    assert not out[p:-p, p:-p].any()


@pytest.mark.parametrize("name", list(KERNELS))
def test_no_saturation_by_construction(name: str) -> None:
    """Сдвиги подобраны так, что даже худший случай помещается в 0..255 без насыщения."""
    w = KERNELS[name].weights.astype(np.int64)
    worst = max(255 * w[w > 0].sum(), -255 * w[w < 0].sum())
    assert (worst + (1 << KERNELS[name].shift >> 1)) >> KERNELS[name].shift <= 255


def test_postprocess_rounding_and_clamp() -> None:
    acc = np.array([-20, -1, 0, 7, 8, 9, 4095, 4096, 100000])
    # shift=4: деление на 16 с округлением половины вверх, затем насыщение.
    np.testing.assert_array_equal(
        postprocess(acc, 4, "clamp"), [0, 0, 0, 0, 1, 1, 255, 255, 255]
    )
    np.testing.assert_array_equal(postprocess(acc, 4, "abs"), [1, 0, 0, 0, 1, 1, 255, 255, 255])


def test_rgb565_extremes() -> None:
    np.testing.assert_array_equal(rgb565_to_rgb888(np.array([0x0000])), [[0, 0, 0]])
    np.testing.assert_array_equal(rgb565_to_rgb888(np.array([0xFFFF])), [[255, 255, 255]])
    np.testing.assert_array_equal(rgb565_to_rgb888(np.array([0xF800])), [[255, 0, 0]])


def test_gray_formula() -> None:
    # Белый: (77 + 150 + 29) * 255 >> 8 = 255; коэффициенты в сумме дают ровно 256.
    rgb = np.array([[255, 255, 255], [255, 0, 0], [0, 255, 0], [0, 0, 255], [0, 0, 0]])
    np.testing.assert_array_equal(rgb888_to_gray(rgb), [255, 76, 149, 28, 0])


def test_pipeline_chains_kernels() -> None:
    img = random_image()
    chain = [KERNELS["gauss5"], KERNELS["gauss5"], KERNELS["log5"]]
    expected = convolve(convolve(convolve(img, chain[0]), chain[1]), chain[2])
    np.testing.assert_array_equal(pipeline(img, chain), expected)


def test_kernel_validation() -> None:
    with pytest.raises(ValueError):
        Kernel("big", np.array([[200]]), shift=0, mode="clamp")
    with pytest.raises(ValueError):
        Kernel("even", np.ones((2, 2), dtype=int), shift=0, mode="clamp")


def test_pad_kernel_keeps_result_inside_larger_border() -> None:
    """Ядро 3×3, дополненное до 5×5, считает то же, но рамка становится шириной 2."""
    img = random_image()
    small = KERNELS["identity"]
    padded = pad_kernel(small, 5)
    assert padded.size == 5
    np.testing.assert_array_equal(convolve(img, padded)[2:-2, 2:-2], img[2:-2, 2:-2])
    assert not convolve(img, padded)[:2].any()


def test_kernel_rom_layout() -> None:
    k = 5
    rom = kernel_rom_bytes(k)
    entry = k * k + 1
    assert len(rom) == entry * len(KERNEL_ROM_ORDER)
    for n, name in enumerate(KERNEL_ROM_ORDER):
        kernel = pad_kernel(KERNELS[name], k)
        record = rom[n * entry : (n + 1) * entry]
        weights = [b - 256 if b > 127 else b for b in record[:-1]]
        assert weights == kernel.weights.flatten().tolist()
        assert record[-1] & 0x0F == kernel.shift
        assert bool(record[-1] & 0x80) == (kernel.mode == "abs")


@pytest.mark.parametrize("size", [(160, 120), (16, 12)])
def test_sample_image_is_deterministic_and_varied(size: tuple[int, int]) -> None:
    w, h = size
    img = sample_image(w, h)
    assert img.shape == (h, w) and img.dtype == np.uint8
    np.testing.assert_array_equal(img, sample_image(w, h))
    assert len(np.unique(img)) > 8


def test_gray_to_rgb() -> None:
    np.testing.assert_array_equal(gray_to_rgb(np.array([0, 255, 128])), [0x0000, 0xFFFF, 0x8410])
    # RGB666: 18 бит, 128 -> 0b100000 в каждом канале.
    np.testing.assert_array_equal(
        gray_to_rgb(np.array([0, 255, 128]), (6, 6, 6)), [0, 0x3FFFF, 0b100000_100000_100000]
    )


def test_display_frame_scales_and_centers() -> None:
    img = np.array([[10, 20], [30, 40]], dtype=np.uint8)
    screen = display_frame(img, 7, 6, scale=2)
    # Картинка 4×4 со смещением ((7-4)//2, (6-4)//2) = (1, 1).
    assert screen.shape == (6, 7)
    assert screen[1, 1] == screen[2, 2] == gray_to_rgb(np.array([10]))[0]
    assert screen[1, 3] == gray_to_rgb(np.array([20]))[0]
    assert screen[4, 4] == gray_to_rgb(np.array([40]))[0]
    assert screen[0].sum() == 0 and screen[:, 0].sum() == 0 and screen[:, 5:].sum() == 0


def test_decimate_takes_top_left_of_each_block() -> None:
    img = np.arange(8 * 12).reshape(8, 12)
    np.testing.assert_array_equal(decimate(img, 4, 3, 2), [[0, 4, 8], [48, 52, 56]])
    # Лишние пиксели справа и снизу отбрасываются.
    np.testing.assert_array_equal(decimate(img, 4, 2, 1), [[0, 4]])
    with pytest.raises(ValueError):
        decimate(img, 4, 4, 2)
