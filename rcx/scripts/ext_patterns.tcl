# Step D of the OpenRCX rules flow: extract the pattern layout with the new rules and
# write SPEF, to be compared with the reference (rcx/validation/compare_patterns.py).
# env: BP55_ROOT, RULES_OUT, EXT_SPEF
read_lef $::env(BP55_ROOT)/pdk/prtech/techLEF/N551P6M_ecos.lef
read_def patterns.def
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file $::env(RULES_OUT) -cc_model 12 -max_res 0 -context_depth 10 -coupling_threshold 0.0
write_spef $::env(EXT_SPEF)
