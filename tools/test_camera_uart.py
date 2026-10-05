"""Тесты итоговой проверки клиента camera_uart.py: успех только при совпадении результата с
моделью и известном периоде кадров камеры."""

import numpy as np
import pytest

import camera_uart


@pytest.fixture
def expected():
    rng = np.random.default_rng(1)
    shape = (camera_uart.HEIGHT, camera_uart.WIDTH)
    return rng.integers(0, 256, shape, dtype=np.uint8)


def test_matching_result_passes(expected):
    assert camera_uart.check(expected.copy(), expected, 798_000) == []


def test_wrong_pixel_fails(expected):
    out = expected.copy()
    out[3, 4] ^= 0x80
    problems = camera_uart.check(out, expected, 798_000)
    assert len(problems) == 1 and "1 of" in problems[0]


def test_unknown_period_fails(expected):
    problems = camera_uart.check(expected.copy(), expected, 0)
    assert len(problems) == 1 and "period" in problems[0]
