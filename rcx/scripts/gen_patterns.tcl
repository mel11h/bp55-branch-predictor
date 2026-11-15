# Step A of the OpenRCX rules flow: pattern layout from the tech LEF.
# MET1-MET5 and T4M2 (-met_cnt 6): the re-run layouts route a few signal nets on T4M2;
# RDL (pad layer) is left out.
read_lef $::env(BP55_ROOT)/pdk/prtech/techLEF/N551P6M_ecos.lef
bench_wires -met_cnt 6 -len 100 -all
bench_verilog patterns.v
write_def patterns.def
