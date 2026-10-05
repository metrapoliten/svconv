"""Тесты анализатора отчёта Gowin check_lcd_timing.py на коротких отчётах в формате сводки .tr."""

import pytest

import check_lcd_timing as c

HEADER = [
    "  Path Number   Path Slack   From Node   To Node   From Clock   To Clock   Relation   "
    "Clock Skew   Data Delay",
    " ============= ============ =========== ========= ============ ========== ========== "
    "============ ============",
]
DATA_PORTS = ["lcd_de_o_obuf/O"] + [f"lcd_{ch}_o_{i}_obuf/O" for ch in "rgb" for i in range(6)]


def table(command: str, rows: list[str]) -> list[str]:
    return [f"<Report Command>:report_timing -{command}", *HEADER, *rows, ""]


def data_rows(skew: float, delay: float) -> list[str]:
    return [
        f"  {n + 1}  1.000  reg_{n}/Q  {port}  lcd_clk:[R]  lcd_clk:[R]  28.571  {skew}  {delay}"
        for n, port in enumerate(DATA_PORTS)
    ]


def dclk_row(edge: str, skew: float, delay: float) -> list[str]:
    return [
        f"  1  1.000  u_lcd_clk_oddr/Q0  lcd_clk_o_obuf/O  lcd_clk:[{edge}]  lcd_clk:[R]  "
        f"14.286  {skew}  {delay}"
    ]


def report(dclk_edge: str = "F") -> list[str]:
    """Отчёт в духе настоящего: медленный угол — задержки больше, быстрый — меньше."""
    to_data = "-to [get_ports {lcd_de_o lcd_r_o[*] lcd_g_o[*] lcd_b_o[*]}]"
    to_dclk = "-fall_from_clock [get_clocks {lcd_clk}] -to [get_ports {lcd_clk_o}]"
    return [
        *table(f"setup {to_data}", data_rows(8.8, 2.9)),
        *table(f"hold {to_data}", data_rows(3.8, 2.6)),
        *table(f"setup {to_dclk}", dclk_row(dclk_edge, 8.4, 3.9)),
        *table(f"hold {to_dclk}", dclk_row(dclk_edge, 4.0, 3.9)),
    ]


def test_margins_from_falling_dclk():
    data, fall, setup, hold = c.margins(report(), "setup")
    assert data == pytest.approx([11.7] * 19)
    assert fall == pytest.approx(c.PERIOD / 2 + 12.3)
    # Спад через 26.586 нс, данные через 11.7: установка 26.586 - 11.7 - 8.
    assert setup == pytest.approx(c.PERIOD / 2 + 12.3 - 11.7 - 8)
    assert hold == pytest.approx(c.PERIOD + 11.7 - fall - 8)
    _, fall, _, _ = c.margins(report(), "hold")
    assert fall == pytest.approx(c.PERIOD / 2 + 7.9)


def test_dclk_path_launched_by_rising_edge_is_rejected():
    with pytest.raises(ValueError, match="falling edge"):
        c.margins(report(dclk_edge="R"), "hold")


def test_missing_report_is_rejected():
    lines = [line for line in report() if "fall_from_clock" not in line]
    with pytest.raises(ValueError, match="no report"):
        c.margins(lines, "setup")


def test_missing_data_output_is_rejected():
    lines = report()
    lines.remove(next(line for line in lines if "lcd_b_o_5_obuf" in line))
    with pytest.raises(ValueError, match="18 data outputs"):
        c.margins(lines, "setup")
