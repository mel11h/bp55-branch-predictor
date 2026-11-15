#!/bin/bash
cd "$(dirname "$0")"; export PATH=~/.local/bin:$PATH; T=${TMPDIR:-/tmp}
python3 icarus_port.py ../../rtl/bp55.sv $T/bp55_icarus.sv
iverilog -g2012 -o $T/x.vvp $T/bp55_icarus.sv tb_bp55_xprop.sv 2>&1 | grep -v sorry
vvp -n $T/x.vvp | tee xprop.log
