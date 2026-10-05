# Сборка camera_lcd_top для Tang Mega 138K Pro. Запускается из каталога сборки (см. Makefile), где
# лежит сгенерированный kernels.hex. Чип — переменные окружения DEVICE и DEVICE_VERSION (см. Makefile).
set board_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize "$board_dir/../../rtl"]
set device $::env(DEVICE)
set device_version $::env(DEVICE_VERSION)

set_device $device -device_version $device_version

foreach f {
  util/level_sync.sv util/button.sv
  core/sdp_ram.sv core/kernel_rom.sv core/conv_postprocess.sv core/conv2d_stage.sv
  core/conv_pipeline.sv core/rgb565_to_gray.sv
  video/video_timing.sv video/frame_buffer.sv video/lcd_frame_reader.sv video/lcd_output.sv
  camera/sccb_writer.sv camera/ov7670_init.sv camera/dvp_capture.sv camera/camera_pipeline.sv
  camera/camera_display.sv
} {
  add_file "$rtl_dir/$f"
}
add_file "$board_dir/camera_lcd_top.sv"
add_file "$board_dir/camera_lcd.cst"
add_file "$board_dir/camera_lcd.sdc"

set_option -top_module camera_lcd_top
set_option -verilog_std sysv2017
set_option -output_base_name camera_lcd
# Регистры, которые прямо выводятся на ножки (RGB и DE дисплея), — в блоки ввода-вывода: у GW5A-138
# по умолчанию выключено. Зачем — см. «Выводы дисплея» в camera_lcd_top.sv.
set_option -oreg_in_iob 1

run all
