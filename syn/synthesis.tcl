set cycle 10
analyze -format verilog  { ../hdl/lenet.v  }

elaborate lenet -architecture verilog 

source compile.tcl
