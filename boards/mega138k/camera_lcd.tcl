# Сборка camera_lcd_top для Tang Mega 138K Pro. Запускается из каталога сборки (см. Makefile), где
# лежит сгенерированный kernels.hex. Чип — переменная окружения DEVICE: по умолчанию инженерная
# версия GW5AST-LV138FPG676AES, как в примерах Sipeed для этой платы; серийная —
# GW5AST-LV138FPG676AC1/I0 (сверить с маркировкой чипа).
set board_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize "$board_dir/../../rtl"]
set device $::env(DEVICE)

set_device $device -device_version B

foreach f {
  util/button.sv
  core/sdp_ram.sv core/kernel_rom.sv core/conv_postprocess.sv core/conv2d_stage.sv
  core/conv_pipeline.sv core/rgb565_to_gray.sv core/frame_decimator.sv
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

run all
