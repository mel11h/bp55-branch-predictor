# rcx: parasitic extraction for BP55 on ICsprout55

A self-made OpenRCX extraction deck for the ICsprout55 back end, the flow that extracts a
detailed-routed BP55 layout into SPEF in three RC corners, and three-corner STA on that SPEF.
It is an open, self-made deck, not a foundry-qualified one: read "How far it can be trusted"
before using any number.

## What the PDK says about the back-end stack

| Item | Source | Value |
|---|---|---|
| Layer order and materials | DRM p.13 (3.2.3 cross-section) | ILD; per 1x level an NDC film ("a") and a BD low-k film ("b"); 4x level in SiN ("c") + PEOX ("d"); passivation SiN/TEOS |
| Drawn width / pitch | DRM p.13, tech LEF | MET1 0.09/0.18, MET2-5 0.10/0.20, T4M2 0.40/0.80 um |
| Optical shrink | DRM p.4; LVS deck l.26, l.188 (`HALF_NODE TRUE`, `scale_value 0.9`) | layout drawn at 65 nm size, silicon is 0.9x |
| Sheet resistance | LVS deck l.249-309; tech LEF RPERSQ | MET1 0.1122, MET2-8 0.0914, T4M1 0.0239, T4M2 0.0177 ohm/sq in the deck; the LEF gives T4M2 0.0239 (the deck's T4M1 value), which is used here |
| Metal resistor model | LVS deck l.3161-3173 and l.249-293 | R = 0.9 L Rs / (0.9 W - 2 dw), dw 0.012485 (MET1) / 0.01246 um (METn) |
| Via resistance | tech LEF | 2.5 ohm per VIA1-4 cut |
| Per-layer C | tech LEF (`_ecos` variant only) | CPERSQDIST and EDGECAPACITANCE, one nominal set |
| Thicknesses | DRM p.105 | only POLY 1000 A and RDL/AL pad 14500 A |
| Cu and dielectric thicknesses, permittivities, RC corners | nowhere | not documented; no ITF, QRC, StarRC, OpenRCX or capacitance tables; PDK README lists "RC extraction" as to-do |

The Liberty corner names (`ss_rcworst`, `ff_rcbest`) refer to RC corners for which the PDK has no data.

## What had to be assumed (rcx/solver/stack.py)

- A1 metal thickness from the sheet resistance with an effective Cu resistivity of 2.0 uOhm cm:
  MET1 0.178 um, MET2-5 0.219 um, T4M2 0.837 um (R itself comes from the PDK Rs, so only C depends on this).
- A2 permittivities: BD 2.9, NDC 4.9, SiN 7.0, oxide (ILD, PEOX, TEOS) 4.1.
- A3 films: ILD 0.30 um, each NDC cap 0.05 um, each 1x via 0.20 um, SiN 0.05 um and T4V2 0.60 um under T4M2.
- A4 the LVS `dw` is a non-conducting liner: R uses 0.9 W - 2 dw, C uses the full 0.9 W.
- A5 RC corners: the PDK gives only nominal values. rcworst = silicon width -8 nm, metal thickness -10 %,
  dielectric films -10 %; rcbest = +8 nm, +10 %, +10 %. Wire R also carries the paired cell-corner
  temperature (TCR 3.0e-3/K: ss 125 C, tt 25 C, ff -40 C). Via R: LEF value, no corner or temperature.

## Method

The standard OpenRCX rules flow, with a field solver written here in place of a commercial
reference extractor:

1. `bench_wires -met_cnt 6 -len 100 -all` on the tech LEF (MET1-MET5 and T4M2): 1184 patterns
   (over, under, over-under, diagonal, resistance families) at minimum width and 12-13 spacings.
2. `solver/patterns2spef.py`: every pattern cross-section is solved with `solver/fd2d.py`, a 2D
   finite-volume Laplace solver (non-uniform grid, exact permittivity interfaces, discrete-Gauss
   charge). Drawn geometry is shrunk 0.9x, corner bias applied, z from `solver/stack.py`.
   The orthogonal context wires of a pattern (OpenRCX `cntxM` nets) are handled 2.5D: the
   cross-sections through a context wire and between two of them are solved and averaged with the
   context density as weight. Totals are written as the reference SPEF of the patterns.
3. `bench_read_spef` + `write_rules` turn it into `rules/bp55_<corner>.rules`.
4. Self-check: the pattern layout is extracted with the new rules and compared with the reference.

A 2D solver was chosen over the analytic fallback because the stack, although assumed, is
described well enough to solve, and a solver gets fringe, shielding and the NDC/BD interfaces
right where closed-form fits do not. No 3D solver (FasterCap or similar) was built or tried within the
budget; the 2.5D averaging is therefore the main geometric approximation and is not checked
against a 3D solution.

Extraction (`scripts/extract.tcl`): `extract_parasitics -max_res 0 -coupling_threshold 0.1
-cc_model 12 -context_depth 5`, coupling caps below 0.1 fF are grounded, SPEF written per corner
and the bracketed non-bus net names that timing repair creates (`f_ckpt[19]4336`) are escaped
(`scripts/fix_spef_names.py`; without it OpenSTA cannot match 34 output nets, STA-1650, and leaves
them unannotated).
STA (`scripts/sta.tcl`): ss Liberty + rcworst SPEF, tt + typ, ff + rcbest; propagated clock; same
reports as the colleague's flow. The estimated-parasitics reference reproduces the published
method exactly (pnr/signoff/sta.tcl: detailed wires dropped, global route, `set_wire_rc`
MET3/MET4 from the LEF, one set for all corners).

## Validation

**Solver against closed forms** (`validation/solver_validation.txt`): parallel plate and two
dielectrics in series exact to 1e-6; thin microstrip vs Hammerstad-Jensen (with strip-thickness
correction) within +0.5 % for w/h 0.25-4; finite-thickness line over a plane vs Sakurai-Tamaru
within -1.5..+2.0 % (formula quoted +-6 %); grid refinement 0.01 -> 0.0025 um moves the coupling
of a minimum-pitch wire by 1.1 %, boundary distance 1.5 -> 6 um by 2 % on ground C. Production grid
(5 nm) error is about 1 %.

**Rules reproduce their reference** (`validation/step_d_<corner>.txt`, OpenRCX's own calibration
step D): extracting the bench patterns with the generated rules returns the solver values exactly
(median, p5 and p95 of OpenRCX/reference = 1.000 for total C of the over, under and over-under
families and for R) in all three corners. The diagonal family does not: OpenRCX adds the
diagonal coupling but keeps the unshielded ground capacitance, so isolated wire pairs on adjacent
layers come out +27..38 % (median over the family, by corner), up to +96 %.

**Generalisation beyond the patterns** (`validation/generalization.txt`): small test layouts
that are not bench patterns, solver vs OpenRCX for a 20 um MET3 wire. With same-layer neighbours
(the common case in BP55) OpenRCX is within -0.3..+6.8 %. A wire with no same-layer neighbour is
+24..+30 % high, because OpenRCX applies the widest-spacing table entry (which still contains the
pattern's far neighbours) and does not scale over/under capacitance with the density of crossing
wires. The deck therefore errs high for sparse wiring.

**Per-layer values** (`validation/per_layer_summary.txt`, per drawn um, minimum width):

| Layer | R typ / rcworst / rcbest (ohm/um) | R LEF | C isolated typ | C dense typ / rcworst / rcbest (fF/um) | C LEF |
|---|---|---|---|---|---|
| MET1 | 1.80 / 3.04 / 1.15 | 1.25 | 0.076 | 0.201 / 0.177 / 0.230 | 0.137 |
| MET2 | 1.26 / 2.08 / 0.82 | 0.91 | 0.052 | 0.193 / 0.169 / 0.220 | 0.189 |
| MET3 | 1.26 / 2.08 / 0.82 | 0.91 | 0.043 | 0.192 / 0.169 / 0.220 | 0.193 |
| MET4 | 1.26 / 2.08 / 0.82 | 0.91 | 0.038 | 0.192 / 0.169 / 0.220 | 0.193 |
| MET5 | 1.26 / 2.08 / 0.82 | 0.91 | 0.036 | 0.209 / 0.185 / 0.239 | 0.131 |

"Dense" = minimum-pitch neighbours on both sides and 50 % crossing wires above and below; 85-94 %
of it is coupling. For MET2-MET4 the dense value agrees with the tech LEF to 2 %, an independent
check of the assumed stack (the LEF capacitance is the only foundry-side C data); MET1 and MET5
disagree (LEF 32 % and 37 % lower), so the LEF numbers there come from an environment or stack the
PDK does not describe. R is 38 % above the LEF value in typ because of the 0.9x shrink and the
liner bias that the LEF RPERSQ/W ignores. rcworst is the classical RC-worst corner: R up 65 %, C
down 12 % (narrower, thinner wires); rcbest the reverse.

**Fill** (`validation/fill_openrcx_test.txt`, `validation/fill_floating_vs_grounded.txt`):
OpenRCX v2.0-17598 ignores DEF FILLS / dbFill shapes completely (a 20 um wire with 120 fill bars
around it: +0.0 %); the same bars as grounded special-net metal add +72 %, matching the solver's
grounded-fill +78 %. It has no floating-fill model. With the solver, floating fill adds only
11-17 % of what grounded fill adds (an isolated MET3 wire: +13..15 % floating against +78..136 %
grounded).

## Results (v1 layouts)

### Extraction totals and comparison with the estimate (typical corner)

| Layout | Extracted wire C | of which coupling | Estimate (set_wire_rc, global route) | Ratio | Per-net ratio median (p5-p95) | Input-pin C | Wire/pin |
|---|---|---|---|---|---|---|---|
| committed v1 (pnr/5_final) | 115.3 pF | 76.5 % | 185.2 pF | 0.62 | 0.52 (0.18-1.01) | 84.9 pF | 1.36 |
| run_v1_newsdc | 155.3 pF | 78.7 % | 219.5 pF | 0.71 | 0.57 (0.22-1.08) | 96.9 pF | 1.60 |
| run_v1_legacy | 143.6 pF | 77.9 % | 209.9 pF | 0.68 | 0.57 (0.22-1.03) | 98.4 pF | 1.46 |

(`results/<layout>/compare_typ_vs_estimate.txt`.) Nets above 20 fF in the estimate: median ratio
0.67-0.75. Summed wire R is 1.6-1.7x the estimate's (1573 vs 979 kohm on the committed layout).
Committed layout: 115 pF over 900 mm of wire is 0.128 fF/um on average, against 0.19 fF/um that
`set_wire_rc -layer MET3` assumes for every wire. The estimate is pessimistic on C because the
LEF value is a dense-environment number (it matches the solver's minimum-pitch case, see the
per-layer table) while BP55's routing layers are only 18-25 % full, and because it uses drawn
lengths where the silicon is 0.9x shorter. It is optimistic on R (no shrink, no liner, no via R,
one temperature).

### STA: worst setup / hold slack (ns) per corner

ss = ss_rcworst_1p08_125 cells + rcworst RC, tt = typ + typ, ff = ff_rcbest_1p32_m40 + rcbest.
"Estimate" is the published method rerun here on the same layout and SDC; "lumped" is the
colleague's routed-wire LEF extraction (pnr/flow/def2spef.py, no coupling) from pnr/run_*/6_sta_routed.log
or pnr/run_committed_sta/.

| Layout, SDC, period | Parasitics | ss setup / hold | tt setup / hold | ff setup / hold |
|---|---|---|---|---|
| committed, legacy, 6.2 | published (README) | +0.10 / 0.00 | +2.47 / +0.12 | +3.42 / +0.06 |
| | estimate (rerun) | +0.091 / +0.015 | +2.462 / +0.118 | +3.428 / +0.062 |
| | lumped (colleague) | +0.329 / -0.029 | +2.583 / +0.106 | +3.505 / +0.055 |
| | **extracted** | **+0.990 / +0.166** | **+2.875 / +0.099** | **+3.630 / +0.051** |
| committed, new SDC, 6.2 | estimate | -1.302 / +0.120 | +1.854 / +0.089 | +2.795 / +0.042 |
| | **extracted** | **+0.021 / +0.110** | **+2.302 / +0.079** | **+2.970 / +0.031** |
| run_v1_newsdc, new SDC, 6.0 | estimate | -0.164 / +0.207 | +1.942 / +0.098 | +2.745 / +0.042 |
| | lumped (colleague) | +0.019 / +0.188 | +2.061 / +0.077 | +2.830 / +0.030 |
| | **extracted** | **+0.524 / +0.104** | **+2.280 / +0.084** | **+2.915 / +0.034** |
| run_v1_newsdc filled, fill as grounded metal (upper bound) | extracted | +0.496 / +0.111 | +2.263 / +0.084 | +2.907 / +0.034 |
| run_v1_legacy, legacy, 5.0 | estimate | -1.661 / +0.016 | +1.135 / +0.124 | +2.151 / +0.066 |
| | lumped (colleague) | -1.518 / -0.014 | +1.208 / +0.094 | +2.205 / +0.049 |
| | **extracted** | **-0.798 / -0.014** | **+1.459 / +0.104** | **+2.312 / +0.054** |

The estimate reproduces the published numbers to 0.01 ns, so the differences below are due to
the parasitics alone.

Critical paths, slow corner (extracted):
- committed, legacy SDC: flop `_46590_` -> XNOR3 compare -> MUX4/MUX2 tree -> AOI/OA select ->
  `f_taken` output, arrival 4.61 ns (estimate: `_46572_` -> `f_taken`, 5.51 ns). The gain is
  0.37 ns of clock insertion delay (0.83 vs 1.20 ns at the launch flop; the legacy SDC references
  IO delays to the ideal clock, so launch latency counts in full) and 0.53 ns of data path.
- committed, new SDC: `f_pc[5]` input -> address buffer tree -> AOI/OAI compare -> three DLY4X2
  hold buffers -> `_49912_/D`, +0.021 ns; the estimate has the same endpoint at -1.302 ns
  (arrival 8.38 vs 6.67 ns).
- run_v1_newsdc: `f_pc[2]` input -> `f_taken` output, +0.524 ns (estimate: `f_taken` -0.164).
- run_v1_legacy: flop `_46578_` -> `f_taken`, -0.798 ns (estimate: `_46592_` -> `f_taken`, -1.661).
- Hold: against the estimate, worst hold slack moves by -0.03..-0.01 ns in tt and ff (smaller
  wire C, faster clock tree) and by -0.10..+0.15 ns in ss, where the clock-tree change dominates.
  The fast-corner hold margin is +0.031..+0.054 ns everywhere; run_v1_legacy keeps a -0.014 ns
  hold violation at `_46617_/D` in the slow corner, as in the colleague's lumped run.

"Unannotated drivers" (about 1100 per run) are the dangling outputs of the clock-tree dummy load
cells (`clkload*/Y`) and ports with no routed wire; every routed net is annotated.

### v2 layout (pnr/run_v2_newsdc, hardened RTL, new SDC, 6.0 ns)

| Parasitics | ss setup / hold | tt setup / hold | ff setup / hold |
|---|---|---|---|
| estimate | -0.417 / +0.238 | +1.826 / +0.103 | +2.597 / +0.044 |
| lumped (colleague, 6_sta_routed.log) | -0.157 / +0.183 | +1.941 / +0.074 | +2.677 / +0.028 |
| **extracted** | **+0.459 / +0.174** | **+2.161 / +0.083** | **+2.734 / +0.033** |
| extracted, fill as grounded metal (bound) | +0.438 / +0.182 | +2.154 / +0.083 | +2.730 / +0.033 |

Critical path (ss): `f_pc[5]` input -> `f_taken` output, +0.459 ns (estimate: `f_pc[4]` ->
`f_taken`, -0.417). Extracted wire C 169.0 pF (78.7 % coupling) against 238.3 pF estimated
(ratio 0.71, per-net median 0.59, p5-p95 0.23-1.07); input-pin C 108.3 pF, wire/pin 1.56.
Grounded fill: total C +1.4 % in every corner (typ 169.0 -> 171.3 pF; MET2 +0.9 %, MET3 +1.1 %,
MET4 +2.4 %, MET5 +1.9 %), setup -0.021 ns in ss. OpenRCX ignoring dbFill was verified on v1 only
and assumed for v2.

### Sensitivity: all extracted capacitance x0.8 and x1.2 (R unchanged)

| Layout, SDC | C scale | ss setup / hold | tt setup / hold | ff setup / hold |
|---|---|---|---|---|
| committed, legacy, 6.2 | 0.8 | +1.155 / +0.194 | +3.015 / +0.097 | +3.731 / +0.050 |
| | 1.0 | +0.990 / +0.166 | +2.875 / +0.099 | +3.630 / +0.051 |
| | 1.2 | +0.827 / +0.137 | +2.719 / +0.101 | +3.527 / +0.053 |
| run_v1_newsdc, new SDC, 6.0 | 0.8 | +0.706 / +0.084 | +2.377 / +0.081 | +2.956 / +0.032 |
| | 1.0 | +0.524 / +0.104 | +2.280 / +0.084 | +2.915 / +0.034 |
| | 1.2 | +0.345 / +0.125 | +2.181 / +0.086 | +2.874 / +0.035 |

(`results/<layout>/cscale_<f>/`.) +-20 % of C moves slow-corner setup slack by about +-0.17 ns
and hold slack by at most 0.03 ns. Even at +20 % C the extracted slack stays well above the
estimate's (+0.83 vs +0.09 ns committed/legacy; +0.35 vs -0.16 ns run_v1_newsdc), so the sign of
the conclusion (the estimate was pessimistic for setup) holds within that band. The hold margin
in the fast corner is +0.03..+0.05 ns in every case and is not sensitive to C.

### Metal fill (run_v1_newsdc, 8_fill.odb: 382 404 fill shapes on MET1-5 and T4M2)

OpenRCX ignores the fill: the extraction of 8_fill.odb is identical to that of 5_final.odb
(per layer, to the 0.1 fF; `results/v1_newsdc/extract_typ.log`). To bound the effect every fill
shape was turned into grounded VSS metal (`scripts/fill_to_ground.tcl`), which is the pessimistic
limit. Wire capacitance, fF (ground + coupling = total):

| Layer | typ without fill | typ, fill grounded | change |
|---|---|---|---|
| MET1 | 101 + 5 = 107 | 104 + 5 = 109 | +2.1 % |
| MET2 | 10259 + 29481 = 39740 | 11021 + 29119 = 40140 | +1.0 % |
| MET3 | 9798 + 51329 = 61127 | 11606 + 50275 = 61881 | +1.2 % |
| MET4 | 7893 + 27119 = 35012 | 9475 + 26296 = 35771 | +2.2 % |
| MET5 | 4849 + 14227 = 19077 | 5914 + 13562 = 19476 | +2.1 % |
| T4M2 | 117 + 81 = 198 | 100 + 78 = 179 | -9.8 % |
| total | 155.26 pF | 157.55 pF | +1.5 % |

rcworst 140.17 -> 142.33 pF (+1.5 %), rcbest 172.66 -> 174.92 pF (+1.3 %). Timing with grounded
fill: slow-corner setup -0.028 ns (+0.524 -> +0.496), tt -0.017, ff -0.008; hold +0.007 ns in ss,
unchanged in tt/ff. Real fill floats; the solver puts floating fill at 11-17 % of the grounded
increase, so the expected effect of this fill is about +0.2 % C and well under 0.01 ns of slack.
Both numbers rest on OpenRCX's handling of the grounded shapes (it is +72 % on an isolated test
wire, matching the solver), and the fill is kept 0.3 um from signal metal by the fill rules, which
is why the design-level effect is small. The T4M2 decrease (on 0.2 pF of wire) is an OpenRCX context-model
effect that was not investigated.

## How far it can be trusted

What is now extracted: every detailed-routed signal and clock net of a layout, from the actual
routed shapes, with distributed R (one RC node per routed shape, LVS-deck sheet resistance with the
0.9x shrink, liner bias and corner temperature, LEF via resistance) and ground plus coupling C from
OpenRCX rules that were fitted to a 2D field solution of an assumed ICsprout55 cross-section, in
three RC corners. Coupling is written to SPEF but STA treats it as grounded (no crosstalk / Miller
analysis), as OpenSTA does without SI.

How far to trust it:
- The extraction machinery is checked: the solver agrees with closed forms to 0.5-2 %; the rules
  reproduce the solver exactly on the over/under patterns; on non-pattern layouts OpenRCX is within
  7 % for wires with same-layer neighbours and 24-30 % high for isolated wires (it errs high).
- The process data is not. Layer order, materials, widths, the shrink and the sheet resistances
  are from the PDK; every thickness and permittivity is assumed (typical 65/55 nm Cu/low-k values).
  The one independent check, the tech-LEF capacitance, agrees for MET2-MET4 at 2 % and disagrees
  for MET1 and MET5 by 32-37 %. A reasonable error band for total C is +-20 %, which moves
  slow-corner setup slack by +-0.17 ns.
- The RC corners are an assumption (+-8 nm width, +-10 % thickness), not foundry corners; there is no
  Cworst/Cbest corner and no on-chip variation.
- Fill is not modelled by OpenRCX; its effect is bounded at +1.5 % C (grounded) and expected at
  about +0.2 % (floating).
- 3D effects are approximated (2.5D averaging of crossing wires, no line-end or via capacitance
  beyond what OpenRCX adds itself); diagonal neighbours on adjacent layers are overestimated.

The main conclusion is robust to these limits: the published estimate (one `set_wire_rc` layer
model for all corners on global routes) put 1.4-1.6x the extracted wire capacitance on the
layout (extracted C is 29-38 % lower) and overstated the slow-corner clock insertion delay by about
0.4 ns; with extracted parasitics every layout (v1 and v2) gains 0.7-1.3 ns of slow-corner setup slack, hold margins stay positive in tt and ff (+0.03 ns in ff).

What it would take to call this calibrated: the foundry's interconnect technology file (ITF/ICT
or the cross-section table with nominal and corner thicknesses, permittivities, etch bias and
temperature coefficients), or a qualified extraction deck (StarRC/QRC/Calibre xRC) to generate the
pattern reference SPEF from instead of the 2D solver; a 3D solve of a sample of patterns; and
silicon or foundry-extractor correlation on a few nets (ring oscillators or a block extracted with
the qualified deck) within the usual +-5 % on C and R.

## Commands

All from the repository root. OpenROAD v2.0-17598 and a Python 3 with numpy and scipy
(`PYTHON`, default `/usr/bin/python3`) are needed. Every OpenROAD and solver call runs in a
`systemd-run --user` scope with a memory cap and waits for `MEM_MIN_GB` (default 4) GB of free
memory; this work ran with `MEM_MIN_GB=3 MEM_HIGH=2600M MEM_MAX=3G` (extraction peaks at 0.3 GB,
STA at 1.3 GB) because the machine rarely had 4 GB free.

```
rcx/scripts/make_rules.sh 2                      # rules: patterns, solver (2 workers), rules, self-check
python3 rcx/validation/solver_validation.py      # solver vs closed forms
python3 rcx/validation/per_layer_summary.py      # per-layer R, C per corner
python3 rcx/validation/fill_floating_vs_grounded.py
BP55_ROOT=$PWD python3 rcx/validation/generalization.py rcx/work/tests/gen
BP55_ROOT=$PWD python3 rcx/validation/fill_openrcx_test.py rcx/work/tests/fill

# one layout: extraction in three corners + three-corner STA (+ the estimate with ESTIMATE=1)
BP55_PERIOD=6.2 ESTIMATE=1 rcx/run_rcx.sh pnr/5_final.def.gz pnr/5_final.v.gz pnr/bp55_legacy.sdc rcx/results/v1_committed
BP55_PERIOD=6.0 IO_REF_FILE=$PWD/pnr/run_v1_newsdc/io_ref_pin.txt \
  rcx/run_rcx.sh pnr/run_v1_newsdc/5_final.odb pnr/run_v1_newsdc/5_final.v.gz pnr/bp55.sdc rcx/results/v1_newsdc

rcx/scripts/run_v1_all.sh                        # every v1 run above, fill bound, sensitivity
rcx/scripts/run_v2.sh                            # v2 layout
python3 rcx/scripts/compare_spef.py A.spef.gz B.spef.gz [--def layout.def.gz --lib cells.lib]
```

The input layout can be a DEF (plain or gzip) or an ODB; the netlist must be the one written with
it. `IO_REF_FILE` is only read by pnr/bp55.sdc; if it does not exist the median slow-corner flop
clock pin is chosen and written there.

## Files

- `run_rcx.sh` the single-command flow; `scripts/` extraction, STA, rules flow, comparison and helper
  scripts; `solver/` stack definition, 2D solver, pattern-to-SPEF; `rules/bp55_{typ,rcworst,rcbest}.rules`
  the OpenRCX decks (+ write_rules logs); `validation/` checks and their outputs.
- `results/<layout>/`: `bp55_<corner>.spef.gz` (gitignored), `estimate.spef.gz`, `extract_<corner>.log`
  (with the per-layer capacitance table), `sta_rcx_<sdc>_<period>.log`, `sta_est_<sdc>_<period>.log`,
  `compare_typ_vs_estimate.txt`, `cscale_<f>/` sensitivity logs.
- `work/` (gitignored): pattern-solver logs; the pattern layout and reference SPEFs are deleted to
  save space and regenerate with `scripts/make_rules.sh`.

### Clock-gated layout (scripts/run_v2_cg.sh)

`BP55_LIBDIR` / `BP55_CELL_LEF` (from `cg/env.sh`) make `scripts/sta.tcl` read the completed ICG
Liberty. Coupled extraction of the hold-repaired gated layout found hold violations on input-to-flop
paths that the lumped extraction had not shown (-0.112 ns ss); after a targeted delay-cell repair
(`pnr/flow/5_eco_delay.tcl`) the final layout meets setup and hold in all corners with and without
grounded fill. The layout with the balanced clock tree
(`pnr/flow/cts_balance.tcl`) was extracted the same way: `results/v2_cg2_bal` (before its hold repair),
`results/v2_cg2_bal2` and `results/v2_cg2_bal2_fillgnd` (final). The second balancing pass on
the routed wires (experiment) is in `results/v2_cg2_bal3_unfrozen`, `v2_cg2_bal3`, `v2_cg2_bal4`
and `v2_cg2_bal4_fillgnd`. Numbers and history in `cg/README.md`;
results in `results/v2_cg2_eco*` and `results/v2_cg2_bal*`.
