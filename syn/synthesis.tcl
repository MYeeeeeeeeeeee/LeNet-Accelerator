set cycle 10

analyze -format sverilog ../hdl/package.pkg

set fp [open "filelist.f" r]
set rtl_files [split [string trim [read $fp]] "\n"]
close $fp

# Remove package from filelist
set rtl_files [lrange $rtl_files 1 end]

analyze -format sverilog $rtl_files

elaborate lenet

source compile.tcl