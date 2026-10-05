// Тактовые сигналы camera_uart_top: генератор 27 МГц и PCLK камеры (до 27 МГц: XCLK = 27 МГц,
// без делителя). Домены асинхронны: обмен — через кадровые буферы и синхронизаторы.
create_clock -name clk27 -period 37.037 [get_ports {clk27_i}]
create_clock -name pclk -period 37.037 [get_ports {cam_pclk_i}]
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {pclk}]
// Входы камеры (даташит OV7670 v1.4, таблица 4): D[7:0], HREF и VSYNC меняются после спада PCLK
// через 0..5 нс (tPDV, tPHH/tPHL; VSYNC — по спаду при COM10[2] = 0), ПЛИС выбирает их по фронту.
// К максимуму добавлена 1 нс на разницу длины проводов.
set_input_delay -clock pclk -clock_fall 6.0 -max [get_ports {cam_data_i[*] cam_href_i cam_vsync_i}]
set_input_delay -clock pclk -clock_fall 0.0 -min [get_ports {cam_data_i[*] cam_href_i cam_vsync_i}]
// Худшие пути от входов камеры — отдельно в отчёте (.tr, раздел Timing Report By Analysis Type).
report_timing -setup -from [get_ports {cam_data_i[*] cam_href_i cam_vsync_i}] -max_paths 3
report_timing -hold -from [get_ports {cam_data_i[*] cam_href_i cam_vsync_i}] -max_paths 3
