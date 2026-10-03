# Сборка camera_lcd для Tang Primer 20K. Запускается из каталога сборки (см. Makefile), где
# лежит сгенерированный kernels.hex. Верхний модуль (дисплей 4,3" или 5") — переменная
# окружения TOP: camera_lcd_43_top или camera_lcd_50_top.
set board_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize "$board_dir/../../rtl"]
set top $::env(TOP)

set_device GW2A-LV18PG256C8/I7 -device_version C

foreach f {
  util/button.sv
  core/sdp_ram.sv core/kernel_rom.sv core/conv2d_stage.sv core/conv_pipeline.sv
  core/rgb565_to_gray.sv core/frame_decimator.sv
  video/video_timing.sv video/frame_buffer.sv video/lcd_frame_reader.sv video/lcd_output.sv
  camera/sccb_writer.sv camera/ov7670_init.sv camera/dvp_capture.sv camera/camera_display.sv
} {
  add_file "$rtl_dir/$f"
}
add_file "$board_dir/camera_lcd_top.sv"
add_file "$board_dir/camera_lcd.cst"
add_file "$board_dir/camera_lcd.sdc"

set_option -top_module $top
# T10 (кнопка), C10 (PWDN камеры) и N9 (LCD R[2]) — двухфункциональные выводы SSPI; ПЛИС
# загружается через JTAG/MSPI, поэтому их можно использовать как обычные (как в примерах Sipeed).
set_option -use_sspi_as_gpio 1
set_option -verilog_std sysv2017
set_option -output_base_name $top

run all
