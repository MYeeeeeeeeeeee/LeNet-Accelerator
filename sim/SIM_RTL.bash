vcs -R -full64 -sverilog \
    -timescale=1ns/1ps \
    +define+CYCLE=10 \
    -debug_access+all \
    -f sim_rtl.f \
    -top tb_top \
    -o simv
