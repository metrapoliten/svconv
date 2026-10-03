// Тактовые сигналы camera_uart_top: генератор 27 МГц и PCLK камеры (до 27 МГц: XCLK = 27 МГц,
// без делителя). Домены асинхронны: обмен — через кадровые буферы и синхронизаторы.
create_clock -name clk27 -period 37.037 [get_ports {clk27_i}]
create_clock -name pclk -period 37.037 [get_ports {cam_pclk_i}]
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {pclk}]
