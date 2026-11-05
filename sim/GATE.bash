#!/usr/bin/env bash
set -o pipefail

vcs -R \
    -f sim_gate.f \
    -v /cad/Design_Kit/CBDK_IC_Contest_v2.5/Verilog/tsmc13_neg.v \
    +define+GATESIM \
    -debug_access+all \
    2>&1 | tee gate_sim.log
