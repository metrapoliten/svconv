# Сборка camera_uart_top для Tang Primer 20K. Запускается из каталога сборки (см. Makefile),
# где лежит сгенерированный kernels.hex.
set board_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize "$board_dir/../../rtl"]

set_device GW2A-LV18PG256C8/I7 -device_version C

foreach f {
  util/uart_tx.sv util/uart_rx.sv
  core/sdp_ram.sv core/kernel_rom.sv core/conv_postprocess.sv core/conv2d_stage.sv
  core/conv_pipeline.sv core/rgb565_to_gray.sv core/frame_decimator.sv
  video/frame_buffer.sv
  camera/sccb_writer.sv camera/ov7670_init.sv camera/dvp_capture.sv camera/camera_pipeline.sv
  bench/camera_uart.sv
} {
  add_file "$rtl_dir/$f"
}
add_file "$board_dir/camera_uart_top.sv"
add_file "$board_dir/camera_uart.cst"
add_file "$board_dir/camera_uart.sdc"

set_option -top_module camera_uart_top
# T9 (PWDN камеры, контакт J14-6) — двухфункциональный вывод SSPI; ПЛИС загружается через
# JTAG/MSPI, поэтому его можно использовать как обычный (как в примере Sipeed WS2812).
set_option -use_sspi_as_gpio 1
set_option -verilog_std sysv2017
set_option -output_base_name camera_uart

run all
