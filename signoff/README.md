# signoff/ : open-tool DRC, antenna and LVS for BP55 (not foundry sign-off)

The ICsprout55 PDK ships its rule decks only in Calibre format. This directory holds a hand
translation of those decks to KLayout 0.28 and the scripts around it. Nothing here is foundry
sign-off; read `drc/coverage.tsv` before reading any result as "clean".

One command per layout (memory-capped, waits for >= 4 GB free):

    signoff/run_signoff.sh --gds pnr/bp55.gds.gz --verilog pnr/5_final.v.gz --out signoff/results/v1_committed

| path | what |
|---|---|
| `drc/icsprout55_drc.drc` | KLayout DRC: BEOL, contact, FEOL, density, metal fill; Calibre rule names kept |
| `drc/icsprout55_antenna.drc` | KLayout antenna check from the `.ant` deck |
| `drc/coverage.tsv`, `drc/coverage_antenna.tsv` | status of every deck rule: translated / approximated / precondition / not translated, with reason |
| `drc/make_coverage.py` | regenerates `coverage.tsv` from the expanded deck |
| `lvs/icsprout55_lvs.lvs` | KLayout device-level LVS (core SVT MOS, 3-terminal compare + well-tie report) |
| `lvs/run_cell_lvs.sh` | per-cell LVS of library cells against their own CDL |
| `tools/tvf_expand.tcl`, `tools/svrf_pp.py`, `tools/deck_rules.py` | expand the TVF deck to flat SVRF, resolve `#IFDEF`, list rules |
| `tools/cdl_flatten.py`, `tools/verilog2spice.py` | schematic: flattened CDL + top level from the routed Verilog |
| `tools/layer_inventory.py`, `tools/dump_near.py`, `tools/rdb_summary.py`, `tools/make_cell_array.py` | inspection helpers |
| `tests/` | injected-violation DRC and antenna test layouts and the checker |
| `results/` | summarised results per layout (report databases are git-ignored) |

Regenerate the expanded deck and the coverage table:

    tclsh signoff/tools/tvf_expand.tcl pdk/pv/DRC/ICsprout_CalDRC_55LLULP1233_REV1_0_OS.drc > work/drc_flat.svrf
    python3 signoff/tools/svrf_pp.py work/drc_flat.svrf work/drc_pp.svrf
    python3 signoff/tools/deck_rules.py work/drc_pp.svrf > work/rules.tsv
    python3 signoff/drc/make_coverage.py work/rules.tsv signoff/drc/icsprout55_drc.drc > signoff/drc/coverage.tsv

Validate the translation (must print PASS for every test):

    klayout -b -r signoff/tests/make_drc_tests.py -rd out=work/drctests.gds
    klayout -b -r signoff/drc/icsprout55_drc.drc -rd gds=work/drctests.gds -rd top=DRC_TESTS -rd report=work/tests.lyrdb -rd sections=beol,cut,feol,fill
    python3 signoff/tests/check_drc_tests.py work/drctests.tsv work/tests.lyrdb
