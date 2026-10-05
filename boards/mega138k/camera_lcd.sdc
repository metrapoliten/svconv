// Тактовые сигналы camera_lcd_top (Mega 138K Pro).
//
// clk50 и PCLK асинхронны: между ними — только синхронизаторы (сброс, режим цепочки). Частоты
// дисплея и XCLK Gowin создаёт сам из настроек PLL; из домена clk50 в домен дисплея путей нет
// (сброс дисплея — от LOCK PLL), с доменом PCLK его связывает только двухтактовый кадровый буфер.
create_clock -name clk50 -period 20.000 [get_ports {clk50_i}]
// PCLK камеры — до 25 МГц (XCLK = 25 МГц, без делителя).
create_clock -name pclk -period 40.000 [get_ports {cam_pclk_i}]
set_clock_groups -asynchronous -group [get_clocks {clk50}] -group [get_clocks {pclk}]
// Входы камеры (даташит OV7670 v1.4, таблица 4): D[7:0], HREF и VSYNC меняются после спада PCLK
// через 0..5 нс (tPDV, tPHH/tPHL; VSYNC — по спаду при COM10[2] = 0), ПЛИС выбирает их по фронту.
// Плюс ±1 нс на разницу пути сигнала и PCLK (оценка с запасом): на модуле ядра дорожки входов
// камеры — 32..51 мм против 52 мм у PCLK (Pinout_Track_Length_Table Sipeed), до 0,15 нс; длин на
// доке в таблице нет, это ещё несколько сантиметров; провода разной длины (10 и 20 см) — до 0,5 нс.
set_input_delay -clock pclk -clock_fall 6.0 -max [get_ports {cam_data_i[*] cam_href_i cam_vsync_i}]
set_input_delay -clock pclk -clock_fall -1.0 -min [get_ports {cam_data_i[*] cam_href_i cam_vsync_i}]
// Худшие пути от входов камеры — отдельно в отчёте (.tr, раздел Timing Report By Analysis Type).
report_timing -setup -from [get_ports {cam_data_i[*] cam_href_i cam_vsync_i}] -max_paths 3
report_timing -hold -from [get_ports {cam_data_i[*] cam_href_i cam_vsync_i}] -max_paths 3
