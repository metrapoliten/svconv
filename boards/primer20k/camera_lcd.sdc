// Тактовые сигналы camera_lcd_top.
//
// clk27 и PCLK асинхронны: между ними — только синхронизаторы (сброс, конфигурация цепочки).
// Пиксельную частоту LCD Gowin создаёт сам из настроек rPLL; из домена clk27 в домен LCD путей
// нет (сброс LCD формируется от LOCK PLL), а с доменом PCLK его связывает только двухтактовый
// кадровый буфер.
create_clock -name clk27 -period 37.037 [get_ports {clk27_i}]
// PCLK камеры — до 27 МГц (XCLK = 27 МГц, без делителя). Пин F13 не является выделенным
// тактовым входом, поэтому Gowin ведёт PCLK по обычной трассировке (предупреждение PR1014);
// тайминги внутри домена с учётом этого проверяются анализатором.
create_clock -name pclk -period 37.037 [get_ports {cam_pclk_i}]
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {pclk}]
