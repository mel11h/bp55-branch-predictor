# Step C of the OpenRCX rules flow: reference SPEF of the patterns -> rules file.
# env: BP55_ROOT, PAT_SPEF, RULES_OUT
read_lef $::env(BP55_ROOT)/pdk/prtech/techLEF/N551P6M_ecos.lef
read_def patterns.def
bench_read_spef $::env(PAT_SPEF)
write_rules -file $::env(RULES_OUT)
