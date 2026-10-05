"""Запас по установке и удержанию на входе панели (ILI6122) по отчёту Gowin после сборки
camera_lcd_top (Mega 138K Pro); запускается из boards/mega138k/Makefile:

    python3 tools/check_lcd_timing.py build/mega138k/camera_lcd/impl/pnr/camera_lcd.tr

Gowin не сравнивает выходы с DCLK, выведенным на ножку (см. boards/mega138k/camera_lcd.sdc), но
считает задержку каждого выхода от такта PLL: такт до регистра (Clock Skew) плюс регистр и буфер
(Data Delay). Для RGB и DE это задержка смены данных после фронта такта, для DCLK (путь из ODDR,
запущенный спадом такта, lcd_clk:[F]) — задержка спада DCLK, по которому панель защёлкивает
данные. Отчёты -setup дают задержки медленного угла, -hold — быстрого; запас считается в каждом.
"""

import sys

PERIOD = 1000 / 35  # нс, такт дисплея
SETUP = HOLD = 8.0  # нс, ILI6122: tDST/tEST и tDHD/tEHD
DCLK_FROM = "u_lcd_clk_oddr/Q0"
DATA_PORTS = 1 + 3 * 6  # DE и RGB666


def report_rows(lines: list[str], command: str) -> list[list[str]]:
    """Строки таблицы путей из сводки отчёта с командой command (после «report_timing -»)."""
    head = f"<Report Command>:report_timing -{command}"
    starts = [i for i, line in enumerate(lines) if line.startswith(head)]
    if not starts:
        raise ValueError(f"no report 'report_timing -{command}...' in the timing report")
    rows = []
    for line in lines[starts[0] + 3 :]:  # команда, заголовок, линейка
        if not line.strip():
            break
        rows.append(line.split())
    return rows


def data_latencies(rows: list[list[str]]) -> list[float]:
    """Задержки смены RGB и DE на ножках, нс от фронта такта PLL."""
    data = {}
    for _, _, _, dst, src_clk, _, _, skew, delay in rows:
        if not src_clk.endswith("[R]"):
            raise ValueError(f"data output {dst} launched by {src_clk}, expected the rising edge")
        data[dst] = float(skew) + float(delay)  # у каждой ножки свой регистр — один путь
    if len(data) != DATA_PORTS:
        raise ValueError(f"{len(data)} data outputs in the report, expected {DATA_PORTS}")
    return list(data.values())


def dclk_fall_latency(rows: list[list[str]]) -> float:
    """Задержка спада DCLK на ножке, нс от спада такта PLL."""
    for _, _, src, _, src_clk, _, _, skew, delay in rows:
        if src == DCLK_FROM and src_clk.endswith("[F]"):
            return float(skew) + float(delay)
    raise ValueError(f"no path from {DCLK_FROM} launched by the falling edge")


def margins(lines: list[str], analysis: str) -> tuple[list[float], float, float, float]:
    """Задержки данных, спад DCLK (от фронта такта) и запасы установки и удержания, нс."""
    data = data_latencies(report_rows(lines, f"{analysis} -to [get_ports {{lcd_de_o"))
    fall = PERIOD / 2 + dclk_fall_latency(report_rows(lines, f"{analysis} -fall_from_clock"))
    # Данные этого такта меняются через max(data), следующего — через PERIOD + min(data).
    setup = fall - max(data) - SETUP
    hold = PERIOD + min(data) - fall - HOLD
    return data, fall, setup, hold


def main() -> None:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
    ok = True
    for corner, analysis in (("slow", "setup"), ("fast", "hold")):
        data, fall, setup, hold = margins(lines, analysis)
        print(
            f"LCD outputs, {corner} corner (ns after the PLL clock edge): data change "
            f"{min(data):.3f}..{max(data):.3f}, DCLK fall {fall:.3f}; "
            f"setup slack {setup:.3f} ns, hold slack {hold:.3f} ns"
        )
        ok = ok and setup >= 0 and hold >= 0
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
