# A Weekend Project: A Branch Predictor Without SRAM on an Open 55 nm PDK, from RTL to GDSII

*Part of the series "Fable ile Haftasonu" ("A Weekend with Fable"): weekend-sized engineering projects built with Claude Fable, Anthropic's AI model, as the hands-on engineer. The direction and the decisions about scope came from a human; the design, code, runs and this write-up were produced by the model.*

## Abstract

An open-source 55 nm process design kit, ICsprout55, was released under Apache 2.0 in October 2025. This write-up describes a weekend-sized project built on it: a branch prediction unit (BP55) for a six-stage in-order RV32IM core, taken from an empty directory to a routed layout using only open tools. The PDK ships no memory compiler, so every predictor table is a flip-flop array and the whole design is held to 8132 bits of state. BP55 combines a 128-entry branch target buffer, a 512-entry bimodal table, a small three-table TAGE, a 32-entry indirect target cache and an 8-entry return stack. On 21 programs (CoreMark, Embench-IoT and two custom stress tests, about 295 million instructions) it reaches 9.34 mispredictions per thousand instructions and 94.6 % direction accuracy, a 22 % speedup over a core with no prediction. The RTL matches a bit-accurate C++ model over 63.4 million lookups with zero mismatches. Placed and routed with OpenROAD, the block occupies a 0.185 mm² die with no router or antenna violations and closes timing at 6.2 ns (161 MHz) in the slow corner. The project is small on purpose, and its limits are stated plainly: no sign-off DRC or LVS and no extracted parasitics. After the weekend the design was reviewed independently, hardened for a real pipeline (8523 bits) and measured inside two open RISC-V cores: at an equal bit budget it lowers cycles per instruction by 0.65 % to 2.5 % in CORE-V Wally, depending on whether the baseline's BTB is tagged, and by 2.3 % in CVA6 (Section 8).

## 1. Why this, and why a weekend

Open PDKs were confined to 130 nm and 180 nm for years. ICsprout55 claims to be the most advanced openly available node at its release, and it comes with standard cells, IO cells, design rules and device models. It also calls itself a preview: there is no SRAM compiler and no PLL yet.

That makes it a good target for a short, self-contained experiment. The question for the weekend was simple: can one person, with open tools only, take a non-trivial block all the way to GDSII on this kit, and what breaks along the way?

A branch predictor suits the question well. Its quality depends almost entirely on how much state it holds, and conventional designs keep that state in SRAM. Without SRAM the problem turns into a budgeting exercise: how much accuracy can be bought with flip-flops alone, and is a TAGE-style predictor still worth its complexity at that size?

The scope was fixed up front to keep the project weekend-sized:

- one block, not a processor;
- a trace-driven evaluation instead of a full core simulation;
- small embedded benchmarks that build and run in minutes;
- open tools throughout: Clang, Yosys, OpenROAD, KLayout.

## 2. The constraint that shaped everything

The smallest flip-flop in the library is 6.16 µm². With read multiplexers and write logic, one kilobit of state costs roughly 0.01 mm². The 30 to 250 Kbit that SRAM-based predictors take for granted is out of reach, so the budget was set at about 8 Kbit.

The target is a single-issue, six-stage RV32IM pipeline (IF1, IF2, ID, EX, MEM, WB). Branches resolve in EX: a misprediction costs 3 cycles, and a redirect from ID costs 2.

## 3. Architecture

| Component | Size | Bits |
|---|---|---|
| Branch target buffer (BTB) | 128 entries, direct mapped; 8-bit tag, 3-bit type, 18-bit target | 3840 |
| Bimodal base predictor | 512 × 2 bits | 1024 |
| TAGE | 3 tables × 64 entries; 7-bit tag, 3-bit counter, 1 useful bit; histories 5 / 12 / 28 | 2155 |
| Indirect target cache | 32 entries, 6-bit target history | 870 |
| Return address stack | 8 entries | 243 |
| Total | | 8132 |

Four decisions separate this design from an SRAM-based one.

**Single-cycle prediction.** The tables are small enough that BTB lookup, TAGE and target selection finish in one cycle. There is no fast-predictor-plus-override structure and no override bubble.

**Combinational history folding.** The longest history is 28 bits, so index and tag hashes are XOR trees fed directly from the history register. Recovery after a misprediction only has to restore that one register.

**Filtered history.** Only conditional branches that hit the BTB or are taken enter the history. This removes the problem of inserting history late for instructions that IF1 does not yet know are branches. Against an idealised history containing every branch, the measured loss is under 0.1 MPKI.

**What flip-flop arrays give back.** The periodic reset of the useful bits takes one cycle. Payload bits sit in the smaller non-reset flop. Training uses 92 bits of metadata captured at lookup, so no second read port is needed.

## 4. How it was built

The work went in five steps, each small enough to finish and check before starting the next.

1. **Traces.** The benchmarks were compiled to RV32IM with Clang and run on a purpose-written instruction-set simulator that logs every control-flow instruction. The 18 Embench programs pass their own self-checks on it. CoreMark's self-check was not active in the port used here (its CRCs were verified afterwards), and the two custom programs have no reference value.
2. **Model.** The predictor was designed first as a bit-accurate, trace-driven C++ model. A sweep of 300 configurations over BTB, bimodal, TAGE and indirect-cache sizes picked the design point; 26 further runs tuned histories, tag widths and reset period.
3. **RTL.** The chosen point was written in SystemVerilog, about 270 lines in one module.
4. **Verification.** The RTL was compiled with Yosys CXXRTL and stepped against the model lookup by lookup.
5. **Implementation.** Synthesis with Yosys and ABC, place and route with OpenROAD, GDS merge and rendering with KLayout.

The metrics are MPKI (mispredictions resolved in EX per thousand instructions) and CPI including only branch-related penalty cycles.

## 5. Does it predict well?

| Configuration | Bits | MPKI | Direction accuracy | CPI |
|---|---|---|---|---|
| No prediction | 0 | 81.7 | — | 1.269 |
| BTB + bimodal | 5977 | 16.07 | 89.85 % | 1.056 |
| BTB + gshare | 9059 | 10.80 | 93.35 % | 1.041 |
| BP55 | 8132 | 9.34 | 94.60 % | 1.037 |
| TAGE, 123 Kbit (reference) | 122952 | 5.73 | 96.44 % | 1.018 |

BP55 sits below the bimodal and gshare curves at every budget above about 2.2 Kbit; below that, gshare is ahead. Against gshare it has 13.5 % fewer mispredictions with 10 % fewer bits.

The honest caveat is that on a pipeline with a 3-cycle penalty this is worth only 0.4 % in CPI. TAGE earns its complexity as the penalty grows: with a 12-cycle penalty the CPI gap is 1.146 against 1.130 (assuming a 4-cycle decode redirect; `sim/penalty_sweep.py` reproduces it).

Two further caveats. The design point was chosen on the same 21 programs the results are reported on, about 370 configurations in all with no held-out set, and five programs account for most of the gap to gshare. And "no prediction" is a weak baseline: against a BTB with no direction predictor (CPI 1.214) the speedup is 17 %, not 22 %.

Removing components one at a time shows where the bits pay off. Without the return stack MPKI rises to 10.23; without the indirect cache it rises to 10.70. These are the cheapest structures and the most efficient per bit. Delaying table updates by two branches raises MPKI only to 9.59, so training in EX is good enough.

Two limits show up per program. In `xgboost` and `recurse` even the 123 Kbit TAGE barely helps (7 % and 2 % fewer mispredictions). BP55 is slightly behind gshare on `xgboost`, `huffbench` and `depthconv`; for the last two the cause is its 64-entry tagged tables overflowing, while for `xgboost` larger tables do not help either.

## 6. From netlist to layout

| | Value |
|---|---|
| Die | 430.5 × 430.5 µm (0.185 mm²) |
| Utilisation | 65 % |
| Cell area (excluding fillers) | 0.114 mm² |
| Flip-flops | 8132 |
| Metal usage | MET1 rails; MET2–MET5 signals; MET4/MET5 power straps |
| Wire length / vias | 900 mm / 162,034 |
| Router violations / antenna violations | 0 / 0 |
| Power (typical corner, 167 MHz) | 33 mW |

![Figure 1. The complete routed BP55 layout](pnr/layout_full.png)

*Figure 1. The complete routed BP55 layout (430.5 × 430.5 µm). Blue: MET1, orange: MET2, green: MET3, yellow: MET4, pink: MET5. The regular horizontal and vertical lines are the MET4/MET5 power straps; the gaps in the top-left and bottom-right corners are areas the placer left unused.*

![Figure 2. Close-up of the layout](pnr/layout_zoom.png)

*Figure 2. A 30 × 22 µm close-up from the middle of the core. The thick horizontal blue lines are the MET1 power rails of the standard-cell rows; between them are the cells' internal MET1 connections, with MET2 (vertical) and MET3 (horizontal) signal wires above.*

Timing was closed at a 6.2 ns clock with 0.5 ns input and 0.5 ns output budgets:

| Corner | Setup slack | Hold slack |
|---|---|---|
| Slow (1.08 V, 125 °C) | +0.10 ns | 0.00 ns |
| Typical (1.2 V, 25 °C) | +2.47 ns | +0.12 ns |
| Fast (1.32 V, −40 °C) | +3.42 ns | +0.06 ns |

That is 161 MHz in the slow corner and roughly 267 MHz in the typical one, at block level.

## 7. What went wrong, and what it taught

Most of the weekend's lessons came from the back end.

**The synthesis timing estimate was misleading.** Wire-less synthesis predicted a 2.47 ns critical path in the slow corner (clock-to-Q excluded). In the routed layout the critical path is about 4.3 ns, including 0.24 ns of clock-to-Q. Flip-flop arrays are the reason: their address lines fan out to thousands of multiplexers and need deep buffer trees. An early frequency estimate based on synthesis alone turned out to be optimistic by a wide margin.

**Clock gating did not survive place and route.** Turning write enables into clock-gating cells cut synthesis area by 16 %. The PDK's Liberty file lacks the clock-gating pin attributes for those cells, however, and OpenROAD could not balance the clock tree behind them. The layout uses the ungated netlist. As a result, 48 % of the power goes into flip-flop internal power and 30 % into the clock tree.

**Buffering is expensive.** Clock-tree cells and timing-repair buffers pushed cell area 17 % above the synthesis figure. Hold repair itself was the smaller part: 2,314 violating endpoints and 363 hold buffers, the worst of them on input-to-flop paths.

**Loosening the clock target did not close timing.** The first layout missed 6.0 ns by 0.10 ns in the slow corner; its placement log shows it was placed against a tighter 5.0 ns clock. Re-running the whole flow with a 6.2 ns target missed by 0.15 ns: the tool optimised less against the looser target. What worked was keeping the 6.0 ns layout and checking it against 6.2 ns. In this flow it pays to optimise against a tighter clock than the one used for sign-off; how much tighter was not isolated.

**One self-inflicted problem.** An early run failed hold repair across nearly every flop. The cause was a constraint that applied the 0.10 ns setup uncertainty to hold checks as well.

## 8. After the weekend: review, hardening and two real cores

Sections 1 to 7 describe the weekend version. Afterwards it was handed to independent reviewers, and then put into real cores.

**Review.** On a second machine with a different build of Clang 18, all 273 rows of the results table and all 6300 rows of the 300-configuration sweep come out identical. The audit of the write-up found six statements that contradicted the committed logs; they are corrected in this text. The RTL review found that the block matched its model but that its interface assumed an ideal pipeline.

**Hardening.** A lookup held by a stall advanced the history and the return stack every cycle; a "not a branch" training message could evict an unrelated BTB entry; the tables were never reset; training and redirect messages were level-sensitive; and the 18-bit targets could not leave a 1 MiB region. The hardened RTL has a `f_fire` input (state advances once, when the instruction leaves the first fetch stage), single-cycle `u_fire` and `r_fire` messages, a 64-cycle table clear after reset, and full targets in the indirect cache. It costs 391 bits (8132 to 8523) and about 13 % more logic before mapping. On the 21 programs nothing changes (9.340 MPKI, CPI 1.0367). The co-simulation now runs every record of every trace with random stalls, flushes and random initial state: 294.7 million lookups and 353.8 million compared outputs per run, zero mismatches in four runs. Two limits remain open and documented: a lookup in the cycle of a redirect, and return-stack repair beyond two wrong-path stack operations.

**Physical flow, second pass.** Synthesis and place and route were re-run for both RTL versions with all logs kept and with new constraints: per-port IO budgets, IO delays measured from a real flop's clock pin after clock-tree synthesis, and a timed reset. The weekend RTL then meets 5.98 ns in the slow corner and the hardened RTL 6.16 ns (die 444 µm square, 129,923 µm² of cells, about 7 % more than the weekend RTL under the same constraints). With these constraints no endpoint needs hold repair, so the hold problem of Section 7 was the IO constraint. Checked against the new constraints, the weekend layout of Section 6 meets about 7.0 ns rather than 6.2, and its 6.2 ns closure does not reproduce on a different OpenROAD build (6.52 ns). Clock gating saves 16.4 % of synthesised area in both versions, and the 2.47 ns synthesis figure was ABC's own estimate (zero-wire static timing gives 3.85 ns). Both new layouts were metal-filled to the PDK's density rules with no window below the minimum afterwards. Timing in this pass uses lumped wire RC without coupling.

**Parasitic extraction.** The PDK has no extraction deck and documents no metal or dielectric thicknesses. A rule set for OpenRCX was therefore built from what the PDK does give (layer order, materials, sheet resistance, the 0.9x shrink) and an assumed cross-section, using a small 2D field solver as the reference, and the routed layouts were extracted with coupling in three corners. With those parasitics the hardened layout meets 6.0 ns in the slow corner with 0.46 ns of slack (the global-route estimate gives −0.42 ns), and the weekend layout has +0.99 ns at 6.2 ns instead of +0.09. The estimates were pessimistic because they charge every wire a dense-routing capacitance while the layers are only 18 to 25 % full: 169 pF extracted against 238 pF estimated for the hardened layout. The solver and the fitted rules are validated against closed forms; the process data is not, and ±20 % on capacitance moves slow-corner slack by ±0.17 ns. Grounding every fill shape, an upper bound, costs under 0.03 ns. Crosstalk is not analysed.

**CORE-V Wally** (five stages, RV32IM, measured misprediction penalty 2 cycles). BP55 was added as one more predictor type and the same 21 programs were run in RTL simulation on ten builds that differ only in the predictor. CPI here includes cache misses and load-use stalls.

| Wally build | Predictor state (bits) | CPI | Redirects per 1000 instr. |
|---|---|---|---|
| No prediction | 0 | 1.288 | 90.98 |
| gshare, BP55-sized | 6925 | 1.169 | 31.80 |
| gshare, Wally's default size | 39438 | 1.147 | 21.35 |
| gshare, BP55-sized, call classification fixed | 6925 | 1.160 | 27.48 |
| gshare, BP55-sized, call fix and 12-bit BTB tag | 8461 | 1.138 | 15.94 |
| gshare, default size, call classification fixed | 39438 | 1.136 | 15.81 |
| BP55 | 8523 | 1.130 | 12.25 |

The speedup over no prediction is 13.9 %, against the 22 % of the trace model, because the real penalty is 2 cycles and not 3. Two quirks of stock Wally inflate BP55's lead: calls built without linker relaxation are classified as returns, and its BTB has no tags. Both were then removed by measurement (the last three rows). Against a gshare of its own size with the classification fixed BP55 is 2.5 % faster; once that gshare also has a tagged BTB the lead is 0.65 %, so about three quarters of the equal-budget lead was simply having tags. Against the corrected default gshare, which has 4.6 times as many bits, BP55 is 0.5 % faster. BP55 carries 434 bits of per-instruction state through Wally's pipeline, against 264 for gshare.

**CVA6** (`cv32a60x`, six stages, measured penalty 5 cycles). The block is instantiated unmodified; the front end looks it up with each pre-decoded instruction and sends a repair when BP55's BTB disagrees with the pre-decoder.

| CVA6 build | Predictor state (bits) | CPI | Mispredictions per 1000 instr. |
|---|---|---|---|
| No dynamic prediction | 0 | 1.615 | 50.72 |
| Stock (32-entry BHT, 2-entry return stack) | 162 | 1.493 | 26.69 |
| CVA6's own structures at BP55's budget | 8520 | 1.437 | 15.77 |
| BP55 | 8523 | 1.404 | 9.38 |

At an equal budget BP55 has 2.3 % lower CPI and 40 % fewer mispredictions, is faster on 17 of 21 programs and 0.9 % slower on one. The cost outside the block is larger here: carrying the 104-bit metadata and 67-bit checkpoint with every instruction adds 2014 flip-flops of pipeline state. In both cores every run passes its self-check and retires exactly the instruction count of the instruction-set simulator, and a software replay of the predictor model with the core's timing reproduces the RTL's misprediction count (to 2 in 3.6 million in Wally, to within 0.03 % in CVA6).

Exceptions, interrupts and CSR flushes do not occur in these programs, so those restore paths are wired but unexercised, and neither core's own regression suite was run on the BP55 build.

## 9. What this project is not

- Sign-off DRC and LVS were not run. The PDK's rule decks are in Calibre format, and "zero violations" refers only to the router's own check against the LEF rules; the router also skipped some enclosure rules it does not support.
- The input and output delays are set against an ideal clock while the flops see about 1.2 ns of clock insertion delay. The 161 MHz figure and the zero slow-corner hold slack both sit on IO paths and are shaped by that; neither is a bound on the speed inside a core.
- CPI is compared at equal cycle time. No gshare was laid out to see whether a simpler predictor would clock faster.
- The bit counts exclude the metadata and checkpoint carried with each in-flight instruction (92 + 67 bits in the weekend version, 104 + 67 after hardening). In a real core that is 434 flip-flops in Wally and 2014 in CVA6.
- The 123 Kbit reference is a scaled-up BP55, capped at 64 bits of history and 6 tables, so it understates what an SRAM-based TAGE would do.
- The synthesis logs, the clock-gated place-and-route run and the early failing hold run were not kept, so the 2.47 ns, 16 % and early-hold statements cannot be checked from the repository.
- The timing of Section 6 rests on RC estimates from global routing. The extraction of Section 8 uses an assumed cross-section, not foundry data, and includes no crosstalk analysis.
- Slow-corner hold slack at 6.2 ns is approximately zero.
- The layout and the timing figures in Section 6 belong to the weekend RTL; the hardened RTL was placed and routed separately (Section 8), and its large outputs are regenerated by script rather than stored. The synthesised and routed netlists were not simulated.
- The weekend co-simulation covered the first 300,000 branch records of each trace and no stalls or wrong-path lookups; the hardened RTL closes that gap (Section 8), except for the two open limits listed there.
- In the two cores, exceptions, interrupts and CSR flushes were not exercised, and the measurements are RTL simulations of small programs, not silicon.
- The workloads are small embedded programs. BTB tag aliasing never occurred, so that RTL path is untested, and the tag and target widths were chosen by assumption. The results do not carry over to large code bases.
- The PDK itself is not yet fully silicon-proven, and its maintainers state that it must not be used for volume production.

## 10. Conclusion

A weekend is enough to take a useful branch predictor from nothing to GDSII on an open 55 nm PDK: 8 Kbit of flip-flops, a 0.185 mm² die and 94.6 % direction accuracy, built entirely with open tools. The same weekend also maps the gaps in today's open flow at this node. A memory compiler would bring the largest gain; in these measurements a 123 Kbit TAGE removes a further 39 % of mispredictions. Completing the Liberty attributes of the clock-gating cells comes second and would cut both power and area. Open DRC, LVS and extraction rules are what it would take to check results like these at sign-off quality.

Put into two real cores after the weekend, the hardened block kept an advantage at an equal bit budget (0.65 % to 2.5 % in Wally, 2.3 % in CVA6), though a small one, much of it owed to a tagged BTB rather than to TAGE, and with pipeline state the bit count does not show.

All sources, scripts, logs and the layout are in the project repository.

## References

1. ICsprout 55 nm Open Source PDK documentation. https://icsprout55-pdk-en.readthedocs.io/en/latest/
2. ECOS Team, "ICsprout55 PDK release" announcement, October 2025. https://website-src-mkdocs.vercel.app/en/news/20251020_icsprout55_pdk_release
3. ICsprout55 PDK repository. https://github.com/openecos-projects/icsprout55-pdk
4. A. Seznec, P. Michaud, "A case for (partially) TAgged GEometric history length branch prediction," Journal of Instruction-Level Parallelism, 2006.
5. S. McFarling, "Combining Branch Predictors," DEC WRL Technical Note TN-36, 1993.
6. EEMBC CoreMark. https://github.com/eembc/coremark
7. Embench-IoT. https://github.com/embench/embench-iot
8. T. Ajayi et al., "Toward an Open-Source Digital Flow: First Learnings from the OpenROAD Project," DAC 2019.
9. C. Wolf, "Yosys Open SYnthesis Suite." https://yosyshq.net/yosys/
