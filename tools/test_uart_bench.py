"""Тесты итоговой проверки клиента uart_bench.py: успех только при верных пикселях и периоде."""

import numpy as np
import pytest

import uart_bench


@pytest.fixture
def expected():
    rng = np.random.default_rng(1)
    shape = (uart_bench.HEIGHT, uart_bench.WIDTH)
    return rng.integers(0, 256, shape, dtype=np.uint8)


def test_correct_frame_and_period_pass(expected):
    assert uart_bench.check(expected.copy(), expected, uart_bench.EXPECTED_PERIOD) == []


@pytest.mark.parametrize(
    "period", [0, uart_bench.EXPECTED_PERIOD - 1, 2 * uart_bench.EXPECTED_PERIOD]
)
def test_wrong_period_fails(expected, period):
    problems = uart_bench.check(expected.copy(), expected, period)
    assert len(problems) == 1 and "period" in problems[0]


def test_wrong_pixel_fails(expected):
    frame = expected.copy()
    frame[5, 7] ^= 1
    problems = uart_bench.check(frame, expected, uart_bench.EXPECTED_PERIOD)
    assert len(problems) == 1 and "1 of" in problems[0]
