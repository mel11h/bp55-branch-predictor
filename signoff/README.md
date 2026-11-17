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
| `lvs/cell_level_lvs.sh`, `lvs/netgen_lvs.sh`, `lvs/netgen_setup.tcl` | block LVS with netgen: cell-level (cells as their own layout netlists, checks the wiring) and device-level against the CDL |
| `tools/def2gds_m2.py` | DEF + `ics55_LLSC_H7CR_M2.gds` merge (the cell GDS that matches the `_ecos` LEF used for routing) |
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

## What is checked and what is not

DRC: of the 711 rule checks in the expanded Calibre deck (default switches), 181 are translated,
62 approximated, 17 checked only for their precondition and 451 not translated; about 30 of the
untranslated ones could apply to this block, the rest need layers or structures it does not have
(`drc/coverage.tsv`). Antenna: per-layer ratios, the deck's ACCUMULATE is not modelled.
LVS: 334 of the 341 used cells with devices match their CDL at the deck's 0.1 % W/L tolerance (the 7
that differ are in `results/library/cell_lvs_used_cells.tsv`); the block is compared at cell level
(netgen, cells described by their own layout netlists), so the check covers how the cells are wired,
not a flat transistor-level compare of the whole block. Not checked: flat device-level LVS of the
block, accumulated antenna, parasitic devices, ERC, and anything in the deck that is not translated.

## Results

| layout | cell-level LVS | notes |
|---|---|---|
| pnr/bp55.gds.gz as first committed (merged with the M1-only cell GDS) | no match: signal pins of 338 cell types unconnected | `results/v1_committed/` |
| same DEF merged with `_M2` cell GDS | match (only the 37 unconnected ports and 38 port aliases differ) | `results/v1_committed_m2cells/` |
| pnr/bp55.gds.gz regenerated 2026-11-16 | match, 35,945 cells, 36,165 nets | `results/v1_committed_regenerated/` |
| run_v1_newsdc filled (`_M2` cells) | match, fill floating | `results/v1_newsdc/` |
| run_v2_newsdc unfilled (regenerated GDS) | match, 38,052 cells, 38,314 nets | `results/v2_newsdc/` |
| run_v2_newsdc filled (regenerated GDS) | match, same counts, fill floating | `results/v2_newsdc/` |
| run_v2_cg/gated_cg2_eco (clock-gated, first hold repair), unfilled and filled | match, 29,872 cells, 30,160 nets | `results/v2_cg2_eco/`, `results/v2_cg2_eco/filled/` |
| run_v2_cg/gated_cg2_eco2 (clock-gated, second hold repair), filled | match, 29,968 cells, 30,256 nets | `results/v2_cg2_eco2/filled/` |
| run_v2_cg/gated_cg2_bal2 (clock-gated, balanced clock tree, final), filled | match, 31,389 cells, 31,700 nets | `results/v2_cg2_bal2/filled/` |
| run_v2_cg/gated_cg2_bal4 (experiment: second balancing pass on routed wires), filled | match, 32,627 cells, 32,938 nets | `results/v2_cg2_bal4/filled/` |

"match" means netgen reports the top level as matching uniquely with port errors only: the 37 ports
the Verilog leaves unconnected and the 38 output ports that the netlist ties to another port.

v2 filled DRC (BEOL, contact, fill, density; `results/v2_newsdc/`): all metal density windows pass
(M1-M5, T4M2 at 0.2-0.51), AA fails in 13 of 64 windows and globally (0.197 < 0.25), poly fails in all
64 windows and globally (0.126 < 0.14): there is no AA/poly fill. Fill size, fill-to-fill and
fill-to-metal rules: 0 violations; MnDUM_S_13 (fill to CHIPBLK 351/12, which the library uses as the
cell boundary) fires along the core edge on every layer. Open BEOL items as in v1: M1 spacing to the
0.20 um follow-pin rails (MET1_S_1), V4 PDN arrays at 0.2 um pitch (V4_S_2), dense line ends
(M2/M3/M4_S_5), small M2 pin areas (M2_A_1). Antenna (v2 filled): 0 on every translated rule.

Clock-gated v2 filled DRC (all sections; `results/v2_cg2_eco/filled/`): metal density passes in all
windows, AA fails in 13 of 64 and poly in 64 of 64; fill size and spacing 0; MnDUM_S_13 18,105 over six
layers; MET1_S_1 62,675, M2_A_1 2,720, LU_S_2 9,092 (tap distance); library-cell items as before plus
NW1_S_1, PO_S_9 and PP_EN_3 in ICGX2H7R. Antenna: 0 on all 19 translated rules.
Final gated layout (`results/v2_cg2_eco2/filled/`): same picture; MnDUM_S_13 18,073, MET1_S_1 62,675,
M2_A_1 2,745, LU_S_2 9,092; antenna 0 on all 19 rules.
Balanced-clock gated layout (`results/v2_cg2_bal2/filled/`): same 259 rule names; MnDUM_S_13 17,673,
MET1_S_1 62,656, M2_A_1 2,821, LU_S_2 9,577; antenna 0 on all 19 rules.
Second balancing pass (`results/v2_cg2_bal4/filled/`): same 259 rule names; MnDUM_S_13 17,442,
MET1_S_1 62,656, M2_A_1 2,782, LU_S_2 9,805; antenna 0 on all 19 rules.
