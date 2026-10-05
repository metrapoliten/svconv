"""Тесты помощника фокусировки camera_focus.py: число резкости и картинка для просмотра."""

import numpy as np

import camera_focus
from camera_uart import HEIGHT, WIDTH


def test_sharp_frame_scores_higher_than_blurred():
    rng = np.random.default_rng(1)
    sharp = rng.integers(0, 256, (HEIGHT, WIDTH), dtype=np.uint8)
    # Размытие усреднением 3×3: края мягче, резкость меньше.
    pad = np.pad(sharp.astype(np.int32), 1, mode="edge")
    blurred = sum(
        pad[1 + dy : 1 + dy + HEIGHT, 1 + dx : 1 + dx + WIDTH]
        for dy in (-1, 0, 1)
        for dx in (-1, 0, 1)
    ) // 9
    assert camera_focus.sharpness(sharp) > 4 * camera_focus.sharpness(blurred.astype(np.uint8))


def test_flat_frame_has_zero_sharpness():
    assert camera_focus.sharpness(np.full((HEIGHT, WIDTH), 100, dtype=np.uint8)) == 0


def test_side_by_side_layout():
    gray = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)
    out = np.full((HEIGHT, WIDTH), 7, dtype=np.uint8)
    img = camera_focus.side_by_side(gray, out)
    s = camera_focus.SCALE
    assert img.shape == (HEIGHT * s, (2 * WIDTH + 2) * s)
    assert img[0, 0] == 0 and img[0, (WIDTH + 1) * s] == 255 and img[-1, -1] == 7
