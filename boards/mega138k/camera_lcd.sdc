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
// Выходы на дисплей. Панель (ILI6122) защёлкивает RGB и DE по спаду DCLK, ей нужно 8 нс установки и
// 8 нс удержания. Все 20 сигналов выходят из блоков ввода-вывода по такту PLL (см. «Выводы
// дисплея» в camera_lcd_top.sv), но сравнить данные с DCLK на ножке Gowin не умеет: такт,
// объявленный на выходной ножке, он считает идеальным, без задержки PLL, дерева тактов и буфера.
// Поэтому здесь задержки выходов только отсчитываются от такта PLL (ограничение 0 нс — чтобы
// Gowin их посчитал), а запас относительно DCLK по ним считает tools/check_lcd_timing.py после
// сборки.
// Такт PLL объявлен явно (35 МГц = 50 × 7 / 10): на автоматический такт PLL из sdc сослаться
// нельзя — Gowin создаёт его уже после разбора ограничений.
create_generated_clock -name lcd_clk -source [get_ports {clk50_i}] -master_clock clk50 -multiply_by 7 -divide_by 10 [get_pins {u_pll/CLKOUT0}]
set_output_delay -clock lcd_clk 0 [get_ports {lcd_clk_o lcd_de_o lcd_r_o[*] lcd_g_o[*] lcd_b_o[*]}]
// Отчёты для check_lcd_timing.py: смена данных (по фронту такта) и спад DCLK (ODDR опускает DCLK
// по спаду такта — путь, запущенный спадом); -setup — медленный угол, -hold — быстрый.
report_timing -setup -to [get_ports {lcd_de_o lcd_r_o[*] lcd_g_o[*] lcd_b_o[*]}] -max_paths 40
report_timing -hold -to [get_ports {lcd_de_o lcd_r_o[*] lcd_g_o[*] lcd_b_o[*]}] -max_paths 40
report_timing -setup -fall_from_clock [get_clocks {lcd_clk}] -to [get_ports {lcd_clk_o}] -max_paths 1
report_timing -hold -fall_from_clock [get_clocks {lcd_clk}] -to [get_ports {lcd_clk_o}] -max_paths 1
