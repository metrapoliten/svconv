# Сборка uart_bench_top для Tang Primer 20K. Запускается из каталога сборки (см. Makefile),
# где лежат сгенерированные image.hex и kernels.hex.
set board_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize "$board_dir/../../rtl"]

set_device GW2A-LV18PG256C8/I7 -device_version C

foreach f {
  util/uart_tx.sv util/uart_rx.sv
  core/sdp_ram.sv core/kernel_rom.sv core/conv2d_stage.sv core/conv_pipeline.sv
  bench/frame_rom_source.sv bench/uart_bench.sv
} {
  add_file "$rtl_dir/$f"
}
add_file "$board_dir/uart_bench_top.sv"
add_file "$board_dir/uart_bench.cst"
add_file "$board_dir/uart_bench.sdc"

set_option -top_module uart_bench_top
set_option -verilog_std sysv2017
set_option -output_base_name uart_bench

run all
