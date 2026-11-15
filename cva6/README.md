# BP55 on CVA6: measurement harness (phase 1)

Phase 1 runs CVA6's own predictor inside the core, measures it, and leaves a
marked hook for BP55. BP55 itself is not instantiated yet.

## Commands

```bash
cva6/cva6.sh sweep                  # setup + bench + build nobp/stock/big + 63 runs (PAR=4 default)
PAR=12 cva6/cva6.sh sweep stock big # a subset, 12 simulations in parallel (about 70 MB each)
cva6/cva6.sh report                 # cva6/results/summary.txt and suite.csv
cva6/cva6.sh crosscheck             # cva6/results/crosscheck.txt
```

The steps one at a time:

```bash
cva6/cva6.sh setup                  # fetch cores/cva6 at 742dc82 if missing, apply cva6/patches
cva6/cva6.sh bench                  # bench/build_cva6.sh with GSF=4 CM_IT=60 -> bench/build/cva6
cva6/cva6.sh build stock            # Verilator model of one variant (about 1-3 min, under 400 MB)
cva6/cva6.sh run stock coremark     # one program; writes cva6/results/stock/coremark.csv
```

Builds run inside `systemd-run --user -p MemoryHigh=6G -p MemoryMax=8G` with
`JOBS=4`, and every build and simulation waits until `MemAvailable` is at
least `MIN_FREE_GB` (3). Build products live in `cores/cva6/bp55_work`
(excluded in the clone's `.git/info/exclude`); only the executable is kept
(about 0.9 MB per variant).

After BP55 is integrated (phase 2), the A/B comparison is
`cva6/cva6.sh sweep big bp55 && cva6/cva6.sh report big bp55`.

## Layout

| Path | Contents |
|---|---|
| `cva6.sh` | the harness driver |
| `configs/base.cfg` | common base: cv32a60x with RVC 0 and Zcb 0 |
| `configs/{stock,big,nobp}.cfg` | predictor variants (only predictor fields may change) |
| `configs/bp55.cfg` | phase-2 hook, rejected until BP55 is wired in |
| `configs/base_rvc.cfg` | diagnostic base with RVC 1 (stock cv32a60x), `BASE_CFG=base_rvc` |
| `patches/` | changes to the CVA6 clone, applied by `setup` |
| `tb/bp55_cva6_tb.sv`, `tb/bp55_cva6_main.cpp` | own testbench: core, AXI memory, monitor, ELF loader |
| `tools/mkconfig.py` | generates the configuration package of a variant |
| `tools/bitcount.py` | predictor state bits from the Verilated model |
| `tools/parse_run.py`, `report.py`, `crosscheck.py` | CSV, tables, checks |
| `results/<variant>/<program>.csv` | raw counters, one row per run |
| `results/bits_<variant>.txt`, `summary.txt`, `suite.csv`, `crosscheck.txt` | derived results |
| `../bench/build_cva6.sh` | builds the 21 programs for this harness |

## Integration brief for phase 2 (BP55 into CVA6)

References are to `cores/cva6` at 742dc82 with `cva6/patches` applied, base
configuration cv32a60x with RVC = 0 (one 32-bit instruction per fetch).

### Where CVA6 predicts today

Fetch timing (`core/frontend/frontend.sv`, `core/cache_subsystem/cva6_icache.sv`),
for a fetch PC X requested in cycle n:

| cycle | what happens |
|---|---|
| n | `npc_select` drives `icache_dreq_o.vaddr = X`; the I$ accepts it (IDLE, or READ with a hit) |
| n+1 | I$ READ: tag compare, `dreq_o.valid` with the data; the next request (X+4) is accepted in the same cycle |
| n+2 | data is in `icache_data_q`/`icache_vaddr_q`; `instr_realign` -> `instr_scan` predecode; BHT and BTB are read with `icache_vaddr_q` (flop arrays, same cycle), the RAS top is read; the prediction drives `predict_address` and `bp_valid`, which overrides this cycle's fetch address and kills the request in s2 (X+4). The instruction is pushed into `instr_queue` |

So every prediction is made two cycles after the fetch request, and only for
instructions that predecode as control flow: direct branch and JAL targets come
from the immediate, BHT gives only a direction (2-bit counter, untagged), the BTB
is used only for JALR that is not a return (untagged, valid + 32-bit target),
and the RAS (no repair at all on mispredicts) for returns. A predicted-taken
instruction costs one killed fetch (one bubble) even when it is correct. Updates
come from `resolved_branch` in EX (`branch_unit.sv`): BHT on every conditional
branch, BTB only on a mispredicted non-return JALR; the RAS is pushed and popped
speculatively in the frontend (`ras_push`/`ras_pop`, gated by
`instr_queue_consumed`).

### Attaching a PC-only predictor (BP55 looks up `f_pc` before data exists)

Option A, decode-assisted (fair swap, smallest change). Look BP55 up at CVA6's
existing prediction point: `f_pc = icache_vaddr_q`, `f_fire = instr_queue_consumed[0]`
(the instruction is accepted by the queue; this is also the gate CVA6 uses for its
RAS). Replace `bht_prediction`, `btb_prediction` and `ras_predict` in the
`npc_select`/taken logic of `frontend.sv` with BP55's outputs, but keep
`instr_scan` as the authority on what is a branch: direct targets still from the
immediate, `f_dir` for conditional branches, `f_target` (ITC) for indirect JALR,
`f_ras_top` for returns. Cost: no change to the fetch pipeline, no new kill
cases; the taken bubble stays; the BP55 lookup moves into the same cycle as
realign + predecode + `npc_select`, which is CVA6's critical frontend path today,
so its timing must be checked (not analysed here). Behavioural catch: BP55's filtered history
inserts only branches its own BTB knows or that are taken. At this point
predecode knows every branch, so either keep BP55's rule (bit-compatible with
`sim/bp_model.h`) or feed the exact branch stream and re-tune in the model; the
BTB's direct-branch targets become redundant (3840 of 8132 bits) but the BTB
hit still drives the history filter and the type field.

Option B, true IF1 lookup (what BP55 was designed for). Look up on the request
address: `f_pc = icache_dreq_o.vaddr` (the `fetch_address` of `npc_select`),
`f_fire = icache_dreq_o.req & icache_dreq_i.ready` (request accepted). Use
`f_taken ? f_target : X+4` as the next `npc_d`. This removes the predicted-taken
bubble. What it needs:
- a 2-deep holding queue for the lookup result (`f_taken/f_target/f_type/f_meta/f_ckpt`)
  aligned with the I$ request pipeline: entry pushed at request acceptance, popped
  when `dreq_o.valid` returns for it, dropped by `kill_s1`/`kill_s2`; an I$ miss
  (READ -> MISS) simply holds the entry (the lookup is done once per accepted
  request, not per cycle);
- a predecode check at the `icache_valid_q` stage (where CVA6 predicts now):
  BTB hit on a non-control-flow word, a direct branch/JAL whose immediate target
  differs from `f_target`, or a JAL/return/indirect that the BTB missed. Each is
  a frontend redirect at the cost of today's `bp_valid` kill (refetch from the
  stage-2 PC), i.e. BP55's ID correction maps onto CVA6's
  existing predecode redirect, and needs an `r_*` repair from the frontend
  (`r_ckpt` of that instruction plus its true action);
- repair for every request that is killed after its lookup updated speculative
  state: `kill_s2` by the predecode redirect, `kill_s1/kill_s2` by `replay`
  (instruction queue full: the same PCs are fetched again, so without a repair
  history and RAS would be updated twice for them), and every IF flush.
  The replay must restore the checkpoint of the replayed PC. How often replay
  happens was not measured in phase 1.
Cost: the queue (2 x ~170 bits), a second redirect source with its own repair,
and more wrong-path lookups (the requests in s1/s2 at a frontend redirect).

Option C, a middle way: look up at request acceptance as in B but apply the
prediction only at stage 2 (as A). No bubble removal, so no advantage over A.

Recommendation: start with A (one frontend file, same pipeline, directly
comparable with `big`), then B as the second step if the taken-bubble cycles
(the `FEtk` column of the results) justify it.

### Two halfword slots per fetch word

With RVC = 1 CVA6 fetches 32 bits as two 16-bit slots (`INSTR_PER_FETCH = 2`):
`instr_realign` yields up to two instructions per fetch, `instr_scan` runs per
slot, and the BHT/BTB rows have one column per slot (column = `pc[1]`); the
lowest predicted-taken slot wins. A one-prediction-per-PC predictor indexed by
the fetch address predicts for one slot only. With no compressed code every
instruction is 4-byte aligned, slot 0 holds the only instruction of each fetch
word and slot 1 is never valid, so one prediction per fetch is exact; but on
an RVC = 1 core CVA6's own BHT/BTB then never use column 1, which halves their
effective capacity (the stock cv32a60x 32-entry BHT is effectively 16 entries
for RV32IM code). That is one reason the harness base uses RVC = 0, where
`INSTR_PER_FETCH = 1`, the tables index on `pc[..:2]` and BP55's model applies
unchanged. RVC = 0 needs `cva6/patches/0002` (CVA6 bug: the no-C instruction
queue dropped `cf_valid`). For C code later: either two BP55 lookups per fetch
(pc, pc+2) or a fetch-block BTB that returns the first taken slot; both change
the model.

### Wrong-path work before an EX redirect

CVA6 issues in order, one instruction per cycle, and branches resolve in EX
the cycle after issue. Younger instructions keep flowing until the redirect:
up to 4 in `instr_queue` (`FETCH_FIFO_DEPTH`), 1 in the ID register
(`id_stage.issue_q`), up to 3 more in the 4-entry scoreboard, and one issued in
the resolution cycle itself (cancelled by `flush_unissued`, which clears its
functional-unit valid). The harness measures, for every EX mispredict, how
many younger instructions had entered the instruction queue and how many RAS
operations the frontend applied for them (`wp_instr_hist`, `wp_rasop_hist` in
the CSVs; summary below).

### Contract points of the final interface (rtl/bp55.sv header)

- `f_fire` (option A): `instr_queue_consumed[0] & ~flush_ctrl_if`, and forced
  to 0 in any cycle with `r_fire = 1` (the EX mispredict cycle also asserts
  `flush_ctrl_if`, so the gating is natural). A replayed instruction (queue
  full) is not consumed, so it does not fire twice.
- `r_fire`: one pulse per redirect. EX mispredict: `resolved_branch.valid &
  is_mispredict` with the checkpoint of the branch and its true operation.
  Every other flush (below): a pulse with no operation bits, a plain
  checkpoint restore.
- `f_busy` (64 cycles after reset): BP55 outputs fall-through and ignores
  `f_fire`; in option A the frontend can use CVA6's static fallback (BTFN,
  decode-time JAL) while `f_busy` is high. In these runs the first instruction
  commits about 75 cycles after reset release, so a few early fetches overlap it.
- Return-stack repair is exact for at most two younger wrong-path lookups that
  touch the stack. Measured in option-A terms (the frontend's own RAS operations
  for younger instructions that entered the queue before the EX redirect):
  0, 1 or 2 per mispredict, 2 only once in 4.7 M mispredicts of `big` and 6
  times in 8.4 M of the RVC = 1 base; never more. The number of younger
  wrong-path instructions (lookups) is up to 4 with RVC = 0 (up to 8 with
  RVC = 1, two queues of 4), more than 2 in 29-36 % of mispredicts, so the limit
  holds for stack operations but not for lookups in general; option B adds the
  s1/s2 requests on top.

### Flushes other than branch mispredictions

From `core/controller.sv` and `frontend.sv`: fence, fence.i (also flushes the
I$ and may halt the frontend), sfence.vma / hfence (only with S/H), CSR writes
with side effects (`flush_csr_i`: satp, mstatus and others in `csr_regfile.sv`),
accelerator flush, AMO flush (RVA), and exceptions, interrupts, mret/sret,
debug entry (`ex_valid_i`, `eret_i`, `set_debug_pc_i`, which redirect to the
trap vector or epc). Inside the frontend: `replay` (instruction queue full;
kill_s1 and refetch from `replay_addr`) and the frontend's own predicted-taken
redirect (`bp_valid` -> kill_s2). `flush_bp_i` (clear predictor state) is wired
only when RVU or RVS is set, so never in cv32a60x. For BP55, every flush that
is not an EX mispredict needs an `r_fire` with the checkpoint of the oldest
squashed instruction and no actions: for controller flushes that is the
instruction after the one at commit (`commit_instr_id_commit[0]`), so the
checkpoint must reach commit; in the benchmark runs these flushes do not
occur (`flush_ex` = 0 in every CSV), so they cost correctness, not
performance.

### Carrying metadata and checkpoint (f_meta 104 + f_ckpt 67 = 171 bits per instruction)

The prediction record travels as `branchpredict_sbe_t` (defined in `core/cva6.sv`:
`valid`, `cf`, `predict_address`): `instr_queue` (per-instruction `instr_data_t`
FIFO, 4 deep, plus a 2-deep address FIFO for predicted targets) ->
`fetch_entry_t.branch_predict` -> `decoder.sv` copies it into
`scoreboard_entry_t.bp` -> `id_stage.issue_q` (1) -> scoreboard `mem_q` (4)
-> `issue_read_operands.branch_predict_o` register (1) -> `branch_unit`
(EX), where `resolved_branch` is formed; the scoreboard entry also reaches
commit (`commit_instr_id_commit`). Adding `meta` and `ckpt` fields to
`branchpredict_sbe_t` and to `instr_data_t` (not to the address FIFO, which
holds only predicted-taken entries) carries them everywhere with no other
plumbing, at a cost of about 10 copies (queue 4, ID 1, scoreboard 4, EX operand
register 1, plus the option-B holding queue): roughly 1.7-2.1 kbit of extra flops for
171 bits, i.e. about 20 % of BP55's 8523 state bits. Cheaper alternative: a small
circular buffer in the frontend written at `f_fire` and indexed by a 3-4 bit tag
carried in `branchpredict_sbe_t`, read by the branch unit at resolution and
released at commit or flush; it needs entries for every instruction that can
be in flight between lookup and commit (about 10), or only for control-flow
instructions if the checkpoint for other flushes is taken from a committed
copy kept at commit.
Training (`u_*`): `u_fire = resolved_branch.valid` is already a one-cycle
message per resolved control-flow instruction (the branch unit sees each one
once; no stall holds it), so it meets the single-pulse contract. In option B
the predecode check must also send `u_isbr = 0` for a BTB hit on a
non-control-flow word (phantom). `u_*` can use `resolved_branch` directly in EX (it carries pc,
target, taken, mispredict and cf type); the class (call/return/indirect) must
come from the decoded instruction, which `branch_unit` sees as `fu_data_i`
and `pc_i`.

## Phase-1 decisions and results (2026-11-15)

Testbench: own (`tb/`), not the stock `ariane_testharness` with Spike's
libfesvr. It instantiates only the core (as `corev_apu/src/ariane.sv` does),
one AXI4 slave in front of a flat 64 MB memory in C++ (latency `+mem_lat`,
default 1), and a monitor; the ELF loader and the tohost exit are a few dozen
lines of C++. Console and exit are taken from the store buffer's request port,
because the write-through D$ may merge consecutive stores to `tohost`. No
Spike build, no debug module, CLINT, PLIC or crossbar to compile; a build takes
1-3 min and under 400 MB.

Configuration: cv32a60x with RVC = 0 (`INSTR_PER_FETCH = 1`) and the programs
built `-march=rv32im`. RVC = 0 is a real core option but was broken
(`patches/0002`); with the fix all 21 programs pass. The RVC = 1 core (stock
cv32a60x) was also measured as `base_rvc-stock`: same instruction counts, and,
because its BHT has one column per halfword slot and RV32IM code only ever uses
column 0, a higher direction MPKI (pooled 18.13 against 16.49).

Variants and predictor state bits (from the Verilated model, `results/bits_*.txt`):
`nobp` 0 (static BTFN + decode-time JAL only), `stock` 162 (BHT 32 x 3, RAS
2 x 33), `big` 7464 (BHT 2048 x 3, BTB 32 x 33, RAS 8 x 33; next power of two
would exceed BP55), `bp55` hook only.

Suite results (21 programs, mem_lat 1; `results/summary.txt`, `suite.csv`):

| variant | CPI mean | CPI pooled | MPKI mean | MPKI pooled | dir / ret / ind MPKI (pooled) |
|---|---|---|---|---|---|
| nobp | 1.6467 | 1.6152 | 51.88 | 50.72 | 35.54 / 5.80 / 9.38 |
| stock | 1.5266 | 1.4929 | 27.85 | 26.69 | 16.49 / 0.82 / 9.38 |
| big | 1.4623 | 1.4382 | 16.02 | 15.90 | 12.33 / 0.46 / 3.11 |
| RVC = 1 stock | 1.5331 | 1.4983 | 29.75 | 28.37 | 18.13 / 0.86 / 9.38 |

Misprediction penalty: 5 cycles (issue of the mispredicted instruction to
issue of the correct-path target is 6 cycles, back-to-back issue is 1), the
mode in 20 of 21 programs; nsichneu 11-14 (its code does not fit the 2 KB I$,
so the redirect target misses). A least-squares fit over all program/variant
pairs gives 5.05 cycles per EX mispredict (4.95 without nsichneu) and 0.14 per
correctly predicted taken redirect: the one-cycle fetch bubble is almost always
hidden by the instruction queue at these CPIs.

Cross-checks (`results/crosscheck.txt`): for all 84 runs instret equals
iss/rvsim's count of the ISS twin, committed control flow equals rvsim's
branch count, csr_regfile's own cycle/instret agree, every resolution belongs
to a committed instruction, no exceptions, no non-mispredict flushes.

Findings: (1) `patches/0002`, the RVC = 0 frontend bug; (2) `-mno-relax`
programs call through `auipc; jalr ra`, so with BTB = 0 (stock cv32a60x) every
call mispredicts (the `ind` column; crc32 41.7 MPKI); (3) interp's dispatch
JALR misses even with a 32-entry BTB (47 MPKI); (4) nsichneu runs slower on
`stock` than on `nobp` (CPI 3.51 against 3.44) with fewer mispredicts: wrong
taken predictions start I$ fills on the wrong path, which the blocking 2 KB I$
must finish before the correct path, so the cost of a mispredict there depends
on its direction (penalty 14 on stock and RVC = 1, 11 on nobp and big).

Note: `tb/bp55_cva6_main.cpp`'s comment defines the penalty as the difference
of the two modes; `tools/report.py` (the reported figure) uses the mispredict
mode minus 1, because correctly predicted taken redirects have a gap of 2.
