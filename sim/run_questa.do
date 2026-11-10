# Usage (from the sim/ folder):  vsim -c -do run_questa.do
vlib work
vlog -sv -mfcu -timescale 1ns/1ps +acc \
  ../rtl/axil_slave.sv ../sva/axil_slave_sva.sv ../tb/tb_axil_slave.sv
vsim -assertdebug work.tb_axil_slave
run -all
assertion report -verbose
coverage report -cvg -details
quit -f
