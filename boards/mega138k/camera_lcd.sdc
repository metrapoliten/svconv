// Тактовые сигналы camera_lcd_top (Mega 138K Pro).
//
// clk50 и PCLK асинхронны: между ними — только синхронизаторы (сброс, режим цепочки). Частоты
// дисплея и XCLK Gowin создаёт сам из настроек PLL; из домена clk50 в домен дисплея путей нет
// (сброс дисплея — от LOCK PLL), с доменом PCLK его связывает только двухтактовый кадровый буфер.
create_clock -name clk50 -period 20.000 [get_ports {clk50_i}]
// PCLK камеры — до 25 МГц (XCLK = 25 МГц, без делителя).
create_clock -name pclk -period 40.000 [get_ports {cam_pclk_i}]
set_clock_groups -asynchronous -group [get_clocks {clk50}] -group [get_clocks {pclk}]
