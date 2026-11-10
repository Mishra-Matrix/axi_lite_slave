#!/bin/sh
# Vivado simulator. Usage (from the sim/ folder):  sh run_xsim.sh
xvlog -sv ../rtl/axil_slave.sv ../sva/axil_slave_sva.sv ../tb/tb_axil_slave.sv
xelab -debug typical tb_axil_slave -s axil_sim
xsim axil_sim -runall
