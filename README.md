# BP55: a weekend, an open 55 nm PDK, and a branch predictor built without SRAM

*Weekend engineering blog, series "Fable ile Haftasonu" ("A Weekend with Fable").*

The question for this weekend: can a non-trivial digital block be taken from an empty directory to a routed chip layout on a brand-new open 55 nm process, using only open-source tools? And what breaks along the way?

The block is a **branch predictor** for a small RISC-V processor. The answer is "yes, mostly", and the parts that broke are the most interesting part of this post.

![The routed BP55 layout with headline numbers](linkedin/1_hero_layout.jpg)

> **About the series.** Each post is a weekend-sized engineering project built with Claude Fable, Anthropic's AI model, as the hands-on engineer. The direction and the decisions about scope came from a human; the design, code, runs and write-ups in this repository were produced by the model.

## The short version

- **What:** BP55, a branch prediction unit for a six-stage RV32IM core, taken from RTL to GDSII on the open [ICsprout55](https://github.com/openecos-projects/icsprout55-pdk) 55 nm PDK.
- **The catch:** the PDK has no memory compiler yet, so there is no SRAM. Every table in the predictor is built from individual flip-flops, 8132 of them in total.
- **How well it predicts:** 94.6 % of branch directions correct across 21 programs, which makes the core 22 % faster than one with no prediction at all.
- **How big and how fast:** a 0.43 × 0.43 mm die that closes timing at 161 MHz in the slow corner.
- **How it was checked:** the RTL agrees with a bit-accurate C++ model on 63.4 million lookups, with zero mismatches.
- **What it is not:** a finished, sign-off-clean design. No sign-off DRC/LVS, no extracted parasitics, no integration into a real core. See [What this project is not](#what-this-project-is-not).

If you want the long form, read [ARTICLE.md](ARTICLE.md) (English) or [MAKALE.md](MAKALE.md) (Turkish). The detailed engineering report is in [REPORT.md](REPORT.md) (Turkish).

## A two-minute background

**Why a processor needs to guess.** A processor works like an assembly line: it starts fetching the next instructions before the current one has finished. When it meets a branch (an `if`, a loop, a function return), it does not yet know which way the program will go. It can either wait, or guess and keep working. If the guess is right, no time is lost. If it is wrong, the work done on the wrong path is thrown away; on this pipeline that costs 3 clock cycles.

**What a branch predictor is.** It is the part that makes the guess. It remembers what each branch did in the past and uses that to predict what it will do next. Its quality depends almost entirely on how much it can remember.

**Why "no SRAM" matters.** Chips normally store that memory in SRAM, which is very dense. Real predictors use 30 to 250 kilobits of it. This PDK cannot generate SRAM yet, so the only storage element available is the flip-flop, which is far larger per bit: about 0.01 mm² per kilobit once the read and write logic is included. The realistic budget is therefore about 8 kilobits, and the design question becomes: how much accuracy can 8 kilobits of flip-flops buy?

A few terms used below:

| Term | Meaning |
|---|---|
| PDK | Process design kit: the files a chip factory provides so you can design for its process |
| RTL | The hardware description (here SystemVerilog) that the chip is built from |
| GDSII | The final layout file, the geometry that would be sent to the factory |
| MPKI | Mispredictions per 1000 instructions; lower is better |
| CPI | Clock cycles per instruction; lower is better. Here it counts branch penalties only |
| BTB | Branch target buffer: remembers *where* a branch goes |
| TAGE | A predictor that looks at several different lengths of branch history and picks the best match |

## What was built

BP55 is five small structures working together:

![Bit budget](linkedin/4_bit_budget.png)

| Component | What it does | Size | Bits |
|---|---|---|---|
| Branch target buffer | Remembers that an address holds a branch and where it jumps | 128 entries, direct mapped; 8-bit tag, 3-bit type, 18-bit target | 3840 |
| TAGE | Predicts taken / not taken from the recent history of branches | 3 tables × 64 entries; 7-bit tag, 3-bit counter, 1 useful bit; histories 5 / 12 / 28 | 2155 |
| Bimodal base predictor | Simple per-branch fallback when TAGE has no match | 512 × 2 bits | 1024 |
| Indirect target cache | Predicts jumps whose target changes (function pointers, `switch`) | 32 entries, 6-bit target history | 870 |
| Return address stack | Predicts where a function returns to | 8 entries | 243 |
| **Total** | | | **8132** |

The target pipeline is IF1, IF2, ID, EX, MEM, WB. Branches resolve in EX, so a misprediction costs 3 cycles; a correction made in ID costs 2.

Having only flip-flops is a limitation, but it also allows some shortcuts that an SRAM-based design cannot take:

- **Prediction in a single cycle.** The tables are small enough that the whole lookup finishes in the first fetch stage. There is no second, slower predictor that overrides the first one, and so no bubble when they disagree.
- **Simple history hashing.** The longest history is 28 bits, so the table indexes are plain XOR trees fed from one history register. Recovering from a misprediction means restoring that one register.
- **Filtered history.** Only conditional branches that the BTB already knows, or that are taken, enter the history. This avoids having to insert history late for instructions the first stage does not yet know are branches. Measured cost against an ideal history: under 0.1 MPKI.
- **No second read port.** 92 bits captured at prediction time travel down the pipeline with the instruction, and the tables are trained from those bits in EX.

The module interface (`rtl/bp55.sv`, about 270 lines):

| Port group | Purpose |
|---|---|
| `f_*` | Lookup in IF1, combinational from `f_pc`; speculative history and return-stack update |
| `r_*` | Redirect from ID or EX: restores the 67-bit checkpoint and applies the correct history / stack operation |
| `u_*` | Table training at EX using the lookup metadata |

## How the weekend went

The work was split into five steps, each small enough to finish and check before starting the next.

1. **Traces.** 21 programs (CoreMark, Embench-IoT and two custom stress tests, about 295 million instructions) were compiled to RV32IM with Clang and run on a small purpose-written instruction-set simulator (`iss/rvsim.c`) that logs every branch and jump.
2. **Model.** The predictor was first written as a bit-accurate C++ model (`sim/bp_model.h`). A sweep of 300 configurations picked the design point; 26 more runs tuned history lengths, tag widths and the reset period.
3. **RTL.** The chosen point was written in SystemVerilog as a single module.
4. **Verification.** The RTL was compiled with Yosys CXXRTL and stepped against the model, lookup by lookup: 63.4 million lookups, 0 mismatches.
5. **Implementation.** Synthesis with Yosys and ABC, place and route with OpenROAD, GDS merge and rendering with KLayout.

## Does it predict well?

![Mispredictions per 1000 instructions](linkedin/2_mispredictions.png)

| Configuration | Bits | MPKI | Direction accuracy | CPI |
|---|---|---|---|---|
| No prediction | 0 | 81.7 | n/a | 1.269 |
| BTB + bimodal | 5977 | 16.07 | 89.85 % | 1.056 |
| BTB + gshare | 9059 | 10.80 | 93.35 % | 1.041 |
| **BP55** | **8132** | **9.34** | **94.60 %** | **1.037** |
| TAGE, 123 Kbit (SRAM-class reference) | 122952 | 5.73 | 96.44 % | 1.018 |

Against gshare, the usual choice at this size, BP55 makes 13.5 % fewer mispredictions with 10 % fewer bits. The sweep below shows it sitting under the bimodal and gshare curves at every budget tried.

![Design-space sweep](linkedin/3_design_space.png)

Three honest caveats:

- **The gain over gshare is small on this pipeline.** With a 3-cycle penalty it is worth only 0.4 % in CPI. TAGE pays for its complexity as the penalty grows: with a 12-cycle penalty the CPI is 1.130 against 1.146.
- **The cheapest structures are the most valuable per bit.** Removing the return stack raises MPKI to 10.23; removing the indirect cache raises it to 10.70.
- **Some programs are out of reach.** In `xgboost` and `qrduino`, dominated by data-dependent branches, even the 123 Kbit reference barely helps. In `xgboost`, `huffbench` and `depthconv`, BP55 is slightly behind gshare because its 64-entry tagged tables overflow.

## From netlist to layout

| | Value |
|---|---|
| Die | 430.5 × 430.5 µm (0.185 mm²), 65 % utilisation |
| Cell area, excluding fillers | 0.114 mm² |
| Cells | 81,398 including fillers and taps; 2,596 clock buffers and inverters; 4,024 timing-repair buffers |
| Power grid | MET1 rails, MET4 vertical and MET5 horizontal straps |
| Signal routing | MET2 to MET5, 900 mm of wire, 162,034 vias |
| Router violations / antenna violations | 0 / 0 |
| Clock tree | about 1.2 ns insertion delay and 0.16 ns skew in the slow corner |
| Power, typical corner at 167 MHz | 33 mW (default switching activity) |

Timing of the final layout at a 6.2 ns clock (0.5 ns input and 0.5 ns output budgets):

| Corner | Setup slack | Hold slack |
|---|---|---|
| Slow (1.08 V, 125 °C) | +0.10 ns | 0.00 ns |
| Typical (1.2 V, 25 °C) | +2.47 ns | +0.12 ns |
| Fast (1.32 V, −40 °C) | +3.42 ns | +0.06 ns |

That is 161 MHz in the slow corner and roughly 267 MHz in the typical one, at block level.

![Close-up of the routed layout](linkedin/6_layout_closeup.png)

More renders are in `pnr/`: [the full die](pnr/layout_full.png), [a close-up](pnr/layout_zoom.png) and [the power grid](pnr/layout_pdn_m4m5.png).

## What went wrong

Most of the weekend's lessons came from the back end.

![Synthesis vs. layout timing](linkedin/5_timing_surprise.png)

- **The synthesis timing estimate was badly optimistic.** Synthesis, which ignores wires, predicted a 2.47 ns critical path in the slow corner. After placement the same path was about 4.3 ns. In flip-flop arrays the address lines fan out to thousands of multiplexers and need deep buffer trees.
- **Clock gating did not survive place and route.** It cut synthesis area by 16 %, but the PDK's Liberty file lacks the clock-gating pin attributes and OpenROAD could not balance the clock tree behind the gating cells. The layout is ungated, so 48 % of the power is flip-flop internal power and 30 % is the clock tree.
- **Hold fixing is expensive.** The short feedback paths inside the flop arrays needed hold buffers at more than 8000 endpoints. Cell area ended 17 % above the synthesis figure.
- **Loosening the clock target did not close timing.** The layout optimised for 6.0 ns misses that target by 0.10 ns but meets 6.2 ns. Re-running the whole flow with a 6.2 ns target missed by 0.15 ns, because the tool optimised less. In this flow it pays to optimise about 0.2 ns tighter than the clock you intend to check against.
- **One self-inflicted problem.** An early run failed hold repair across nearly every flop. The cause was a constraint that applied the 0.10 ns setup uncertainty to hold checks as well.

## What this project is not

This is an experiment, not a product. Read this section before relying on any number above.

| Stage | State |
|---|---|
| Architecture and design-space exploration | Done (300 configurations swept) |
| RTL | Done |
| RTL vs. reference model co-simulation | Passes: 63.4 M lookups, 0 mismatches |
| Synthesis (Yosys + ABC) | Done |
| Place and route (OpenROAD) | Done: 0 router violations, 0 antenna violations |
| Timing closure | Closes at 6.2 ns in the slow corner |
| Sign-off DRC / LVS | **Not run** (rule decks are Calibre format) |
| Parasitic extraction | **Not run** (no open extraction rules for this PDK) |
| Gate-level simulation, integration into a core | **Not done** |

- **No sign-off DRC or LVS.** "Zero violations" refers only to the router's own check against the LEF rules.
- **No extracted parasitics.** Timing uses RC estimates from global routing.
- **Slow-corner hold slack is approximately zero** at 6.2 ns.
- **RTL-level verification only.** The synthesised and routed netlists were not simulated, and the block was not integrated into a core. The co-simulation is trace-driven, so wrong-path lookups were not exercised.
- **Small embedded workloads.** BTB tag aliasing never occurred, so that RTL path is untested, and the tag and target widths were chosen by assumption. The results do not carry over to large code bases.
- **CPI covers branch penalties only**: no cache misses or load-use stalls.
- **The PDK is a preview.** Its maintainers state that it is not fully silicon-proven and must not be used for volume production.

## What the weekend says about the open flow

A weekend is enough to get a useful branch predictor to GDSII on an open 55 nm PDK. It also shows where the open flow at this node is still thin:

1. **A memory compiler** would bring the largest gain. In these measurements a 123 Kbit TAGE removes a further 39 % of mispredictions.
2. **Complete Liberty attributes for the clock-gating cells** would cut both power and area.
3. **Open DRC, LVS and extraction rules** are what it would take to check results like these at sign-off quality.

## Repository map

| Path | Contents |
|---|---|
| `rtl/` | `bp55.sv`, the synthesizable RTL |
| `sim/` | `bp_model.h` (bit-accurate C++ model), `bpsim.cc` (trace driver), `cosim.cc` (RTL vs. model), `summ.py`, sweep lists |
| `iss/` | `rvsim.c`, a minimal RV32IM instruction-set simulator that emits control-flow traces |
| `bench/` | Build script, freestanding runtime, CoreMark port and two custom stress programs |
| `syn/` | Yosys/ABC synthesis scripts and gzipped netlists |
| `pnr/` | OpenROAD scripts, constraints, logs, routed netlist, DEF, final GDSII, layout images |
| `pnr/signoff/` | Timing check of the final layout against 6.0 and 6.2 ns clocks |
| `pnr/run_6p2/` | Logs of a rerun with a 6.2 ns target (did not close; kept for reference) |
| `results/` | CSV results of all sweeps, co-simulation logs, charts |
| `linkedin/` | Square images and post drafts |
| `ARTICLE.md` | Full write-up in English |
| `MAKALE.md`, `REPORT.md` | Article and detailed engineering report in Turkish |

Large outputs are gzipped: `pnr/bp55.gds.gz` (final GDSII), `pnr/5_final.def.gz`, `pnr/5_final.v.gz`, `syn/tt_cg.v.gz`, `syn/tt_nocg.v.gz`.

Not in the repository, because they are third-party or can be regenerated: the PDK, the CoreMark and Embench-IoT sources, the branch traces (about 485 MB), compiled binaries and OpenROAD databases.

## Reproducing the results

### Tools

| Tool | Version used | Install |
|---|---|---|
| Clang + LLD with the RISC-V target | 18.1 | distribution package |
| GCC or Clang (host) | any recent | distribution package |
| Python 3 with NumPy and Matplotlib | 3.13 | `pip install numpy matplotlib` |
| Yosys | 0.71 | `pip install pyosys` |
| OpenROAD | 26Q3 | `nix build nixpkgs#openroad` |
| KLayout (Python module) | 0.30 | `pip install klayout` |

The scripts contain absolute paths under `/home/user/bp55` and a Nix store path for OpenROAD. Adjust them to your checkout before running.

### 1. Fetch the PDK and benchmarks

```bash
git clone --depth 1 https://github.com/openecos-projects/icsprout55-pdk pdk
```

Download the RVT Liberty and GDS archives from the PDK's release page (`ics55_LLSC_H7CR_liberty.tar.bz2`, `ics55_LLSC_H7CR_gds.tar.bz2`) and unpack them under `pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/liberty` and `.../gds`.

```bash
git clone --depth 1 https://github.com/eembc/coremark bench/coremark
```

```bash
git clone --depth 1 https://github.com/embench/embench-iot bench/embench-iot
```

### 2. Build the benchmarks and generate traces

```bash
gcc -O2 -o iss/rvsim iss/rvsim.c
```

```bash
cd bench && GSF=4 CM_IT=60 ./build.sh
```

Every program should report `exit=0`. `wikisort` is skipped because it needs floating point.

### 3. Run the predictor model

```bash
cd sim && g++ -O2 -std=c++17 -o bpsim bpsim.cc
```

```bash
./bpsim BP55 LB=7 LBIM=9 LI=5 HT=6 NT=3 LT=6 TT=7 hist=5,12,28 -- ../traces/*.trc > bp55.csv && python3 summ.py bp55.csv
```

`run.sh` runs a list of configurations in parallel; `grid.txt` is the 300-configuration sweep.

### 4. Co-simulate RTL against the model

```bash
cd syn && python3 y.py "read_verilog -sv ../rtl/bp55.sv; hierarchy -top bp55; proc; flatten; opt; memory -nomap; opt; write_cxxrtl ../sim/bp55_rtl.cc"
```

```bash
cd sim && g++ -O2 -std=c++17 -I"$(python3 -c 'import pyosys,os;print(os.path.dirname(pyosys.__file__))')/share/include/backends/cxxrtl/runtime" -o cosim cosim.cc
```

```bash
./cosim 300000 0 1 ../traces/*.trc
```

Arguments: records per trace, table-update delay in branches, and whether to look up non-branch PCs as well. The run ends with `PASS` or `FAIL`.

### 5. Synthesize

Link the typical and slow Liberty files into `syn/` as `tt.lib` and `ss.lib`, then:

```bash
cd syn && ./synth.sh tt_nocg tt.lib 2500 0
```

The last argument enables clock gating (`1`) or not (`0`). The layout uses the ungated netlist; see [What went wrong](#what-went-wrong).

### 6. Place and route

```bash
cd pnr && openroad -exit 1_place.tcl && openroad -exit 2_cts.tcl && openroad -exit 3_route.tcl
```

```bash
python3 def2gds.py && python3 render.py
```

The flow takes about 40 minutes on four cores. `pnr/2_cts_route.tcl` is the first attempt and is kept for history only.

## License

No license has been chosen for this repository yet. The PDK is Apache 2.0; CoreMark and Embench-IoT carry their own licenses and are not redistributed here.

## References

1. [ICsprout 55 nm Open Source PDK documentation](https://icsprout55-pdk-en.readthedocs.io/en/latest/)
2. A. Seznec, P. Michaud, "A case for (partially) TAgged GEometric history length branch prediction," Journal of Instruction-Level Parallelism, 2006.
3. S. McFarling, "Combining Branch Predictors," DEC WRL Technical Note TN-36, 1993.
4. [EEMBC CoreMark](https://github.com/eembc/coremark) and [Embench-IoT](https://github.com/embench/embench-iot)
5. T. Ajayi et al., "Toward an Open-Source Digital Flow: First Learnings from the OpenROAD Project," DAC 2019.
6. [Yosys Open SYnthesis Suite](https://yosyshq.net/yosys/)
