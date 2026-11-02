# Testbench
lenet_tb.v
#conv1_only_tb.sv
# SRAM behavior model
sram_model/SRAM_activation_1024x32b.v
sram_model/SRAM_weight_16384x32b.v
# Add your design here
../hdl/package.pkg
../hdl/lenet.sv
../hdl/conv1.sv
../hdl/conv2.sv
../hdl/conv3.sv
../hdl/fc_buffer.sv
../hdl/shared_line_buffer.sv
../hdl/shared_weight_buffer.sv
../hdl/fc1.sv
../hdl/reload_controller.sv

../hdl/fc2.sv
../hdl/PE.sv


