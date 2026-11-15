// C++ driver for bp55_cva6_tb.sv (BP55 measurement harness on CVA6, phase 1).
//
//   Vbp55_cva6_tb +elf=<file> [+console=<file>] [+max_cycles=<n>] [+mem_lat=<n>]
//
// Loads an RV32 ELF into a flat 64 MB memory at 0x80000000, runs the core from
// reset (boot address 0x80000000) until the program stores its exit code to
// `tohost` (bench/rt_wally/io_wally.S convention), and prints one line
//   BP55CVA6 status=<PASS|FAIL|TIMEOUT> key=value ...
// with whole-program counters from reset release up to and including the
// commit of the program's exit store (the `sw a0,0(t0)` in exit()). That end
// point matches iss/rvsim, which counts up to and including the exit ecall of
// the ISS twin (bench/build_wally.sh), so instret must equal rvsim's count.
//
// Counter definitions (all from the monitor in bp55_cva6_tb.sv):
//   cycles        clock cycles after reset release, up to the exit-store commit
//   instret       committed instructions without exception (CVA6's minstret rule)
//   cond          committed conditional branches (opcode BRANCH)
//   jal, jal_call committed JAL with rd not a link register / with rd = x1|x5
//   jalr_ret      committed JALR, rd not link, rs1 = x1|x5   (iss/rvsim T_RET)
//   jalr_call     committed JALR with rd = x1|x5            (iss/rvsim T_ICALL)
//   jalr_ind      other committed JALR                      (iss/rvsim T_IND)
//   cond_taken    conditional branches resolved taken
//   fe_taken_*    committed control-flow instructions the frontend predicted
//                 taken (branch_predict.cf != NoCF and valid), by class; each
//                 such prediction redirects fetch after the I$ data returned
//   res           branch-unit resolutions (resolved_branch.valid)
//   mp            resolutions with is_mispredict = 1 (each one flushes IF and
//                 the unissued instructions and redirects fetch from EX)
//   mp_dir        mispredicted conditional branches (direction; the target of
//                 a conditional branch is computed from its immediate)
//   mp_ret_nopred / mp_ret_wrong   returns (CVA6 cf_type Return) with no RAS
//                 prediction / with a wrong RAS address
//   mp_ind_nopred / mp_ind_wrong   other JALR with no BTB prediction / with a
//                 wrong BTB target
//   mp_other      any other mispredict (expected 0)
//   flush_ex      cycles with the controller's flush_ex (fence, fence.i, CSR side
//                 effect, exception, eret): flushes that are not mispredicts
//   pen_*         penalty probe, see below
//   wp_instr_hist / wp_rasop_hist   per EX misprediction: number of younger
//                 (wrong-path) instructions that had entered the instruction
//                 queue / number of RAS push or pop operations the frontend did
//                 for them, as histograms "n0:n1:n2:..." (last bin = 16 or more;
//                 whole run, not cut at the exit store); wp_found = mispredicts
//                 whose own queue entry was found (should equal mp)
//   hw_mcycle / hw_minstret   csr_regfile cycle_q / instret_q one cycle after
//                 the exit-store commit (cross-check of cycles / instret)
//   res counts every resolution up to the snapshot, which includes the `j .`
//   after the exit store (resolved in EX before the store commits): with no
//   wrong-path resolution, res = committed control-flow instructions + 1.
//
// Penalty probe: for every resolution, the number of cycles from the issue of
// the resolved instruction to the issue of the next correct-path instruction
// (scoreboard issue_ack). Mispredicted and correctly predicted resolutions are
// kept in separate histograms; the misprediction penalty is the difference of
// their modes (the most common, stall-free case), the means are reported too.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "Vbp55_cva6_tb.h"
#include "verilated.h"
#include "svdpi.h"

namespace {

constexpr uint64_t kMemBase = 0x80000000ull;
constexpr uint64_t kMemSize = 64ull << 20;
// calloc: pages the program never touches are never allocated
uint8_t *mem = static_cast<uint8_t *>(calloc(kMemSize, 1));
uint64_t oob_accesses = 0;
uint64_t axi_errors = 0;

uint32_t tohost_addr = 0, exit_store_pc = 0;
uint32_t tohost_hi = 0;
FILE *console = stdout;
bool trace = false;  // +trace: one stderr line per commit / resolution / tohost store
bool done = false;
uint32_t exit_value = 0;
uint64_t done_cycle = 0;

struct Counters {
  uint64_t cycles = 0, instret = 0, exceptions = 0;
  uint64_t cond = 0, jal = 0, jal_call = 0, jalr_ret = 0, jalr_call = 0, jalr_ind = 0;
  uint64_t cond_taken = 0;
  uint64_t fe_taken_cond = 0, fe_taken_jal = 0, fe_taken_ret = 0, fe_taken_ind = 0;
  uint64_t res = 0, mp = 0, mp_dir = 0, mp_ret_nopred = 0, mp_ret_wrong = 0;
  uint64_t mp_ind_nopred = 0, mp_ind_wrong = 0, mp_other = 0, res_nocf = 0;
  uint64_t flush_ex = 0;
};
Counters c, snap;
bool snapped = false, snap_hw_pending = false;
uint64_t snap_cycle = 0;
uint64_t hw_mcycle = 0, hw_minstret = 0;

// penalty probe
constexpr int kHist = 64;
uint64_t hist_mp[kHist + 1] = {0}, hist_ok[kHist + 1] = {0};
bool probe_pending = false, probe_mp = false;

// wrong-path probe
struct FeEntry { uint32_t pc; uint8_t ras_op; };
constexpr uint64_t kRing = 64;
FeEntry fe_ring[kRing];
uint64_t fe_n = 0, iss_n = 0;  // pushes / issues since the last IF flush
constexpr uint64_t kWp = 16;
uint64_t wp_instr[kWp + 1] = {0}, wp_rasop[kWp + 1] = {0}, wp_found = 0;
uint64_t probe_t0 = 0, probe_t_issue = 0, last_issue_cycle = 0;

bool in_mem(uint64_t a, uint64_t n) { return a >= kMemBase && a + n <= kMemBase + kMemSize; }

uint32_t insn_at(uint32_t pc) {
  if (!in_mem(pc, 4)) return 0;
  uint32_t v;
  memcpy(&v, &mem[pc - kMemBase], 4);
  return v;
}

bool is_link(uint32_t r) { return r == 1 || r == 5; }

bool load_elf(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); return false; }
  std::vector<uint8_t> b;
  uint8_t buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) b.insert(b.end(), buf, buf + n);
  fclose(f);
  auto u16 = [&](size_t o) { uint16_t v; memcpy(&v, &b[o], 2); return v; };
  auto u32 = [&](size_t o) { uint32_t v; memcpy(&v, &b[o], 4); return v; };
  if (b.size() < 52 || memcmp(b.data(), "\x7f" "ELF", 4) != 0 || b[4] != 1 || u16(18) != 0xf3) {
    fprintf(stderr, "%s: not an RV32 ELF\n", path);
    return false;
  }
  uint32_t phoff = u32(28), shoff = u32(32);
  uint16_t phentsize = u16(42), phnum = u16(44), shentsize = u16(46), shnum = u16(48);
  for (int i = 0; i < phnum; i++) {
    size_t p = phoff + (size_t)i * phentsize;
    if (u32(p) != 1) continue;  // PT_LOAD
    uint32_t off = u32(p + 4), paddr = u32(p + 12), filesz = u32(p + 16), memsz = u32(p + 20);
    if (!in_mem(paddr, memsz)) {
      fprintf(stderr, "segment at %08x+%x outside memory\n", paddr, memsz);
      return false;
    }
    memcpy(&mem[paddr - kMemBase], &b[off], filesz);
  }
  // symbols
  uint32_t exit_sym = 0;
  for (int i = 0; i < shnum; i++) {
    size_t s = shoff + (size_t)i * shentsize;
    if (u32(s + 4) != 2) continue;  // SHT_SYMTAB
    uint32_t off = u32(s + 16), size = u32(s + 20), link = u32(s + 24), entsize = u32(s + 36);
    size_t strs = shoff + (size_t)link * shentsize;
    uint32_t stroff = u32(strs + 16);
    for (uint32_t k = 0; k < size / entsize; k++) {
      size_t e = off + (size_t)k * entsize;
      const char *name = (const char *)&b[stroff + u32(e)];
      if (!strcmp(name, "tohost")) tohost_addr = u32(e + 4);
      if (!strcmp(name, "exit")) exit_sym = u32(e + 4);
    }
  }
  if (!tohost_addr || !exit_sym) {
    fprintf(stderr, "%s: symbols tohost/exit not found\n", path);
    return false;
  }
  // the reporting store of exit(): first `sw a0,0(t0)` (0x00a2a023) from exit
  for (uint32_t a = exit_sym; a < exit_sym + 64; a += 4)
    if (insn_at(a) == 0x00a2a023u) { exit_store_pc = a; break; }
  if (!exit_store_pc) {
    fprintf(stderr, "%s: exit store not found after exit()\n", path);
    return false;
  }
  return true;
}

}  // namespace

extern "C" {

long long tb_mem_read(long long addr) {
  uint64_t a = (uint64_t)addr & ~7ull;
  if (!in_mem(a, 8)) { if (oob_accesses++ < 10) fprintf(stderr, "[tb] read outside memory %llx\n", (unsigned long long)a); return 0; }
  uint64_t v;
  memcpy(&v, &mem[a - kMemBase], 8);
  return (long long)v;
}

void tb_mem_write(long long addr, long long data, char strb) {
  uint64_t a = (uint64_t)addr & ~7ull;
  if (!in_mem(a, 8)) { if (oob_accesses++ < 10) fprintf(stderr, "[tb] write outside memory %llx\n", (unsigned long long)a); return; }
  for (int i = 0; i < 8; i++)
    if ((uint8_t)strb >> i & 1) mem[a - kMemBase + i] = (uint8_t)((uint64_t)data >> (8 * i));
}

void tb_axi_error(int kind, long long addr) {
  if (axi_errors++ < 10)
    fprintf(stderr, "[tb] unsupported AXI request kind=%d (1 wrap burst, 2 atomic) at %llx\n", kind,
            (unsigned long long)addr);
}

void tb_cycle() { c.cycles++; }

void tb_commit(int pc_, int bp_cf, int bp_valid, int ex_valid) {
  uint32_t pc = (uint32_t)pc_;
  if (trace) fprintf(stderr, "[%llu] commit %08x %08x ex=%d bp=%d/%d\n", (unsigned long long)c.cycles, pc, insn_at(pc), ex_valid, bp_valid, bp_cf);
  if (ex_valid) { c.exceptions++; return; }
  c.instret++;
  uint32_t i = insn_at(pc), op = i & 0x7f, rd = (i >> 7) & 31, rs1 = (i >> 15) & 31;
  bool fe_taken = bp_valid && bp_cf != 0;  // cf_t: 0 NoCF 1 Branch 2 Jump 3 JumpR 4 Return
  if (op == 0x63) {
    c.cond++;
    if (fe_taken) c.fe_taken_cond++;
  } else if (op == 0x6f) {
    if (is_link(rd)) c.jal_call++; else c.jal++;
    if (fe_taken) c.fe_taken_jal++;
  } else if (op == 0x67) {
    if (is_link(rd)) c.jalr_call++;
    else if (is_link(rs1)) c.jalr_ret++;
    else c.jalr_ind++;
    if (fe_taken) { if (bp_cf == 4) c.fe_taken_ret++; else c.fe_taken_ind++; }
  }
  if (pc == exit_store_pc && !snapped) {
    snap = c;
    snapped = true;
    snap_hw_pending = true;
    snap_cycle = c.cycles;
  }
}

void tb_resolve(int pc_, int target, int mispredict, int taken, int cf_type, int bp_valid) {
  (void)target;
  uint32_t pc = (uint32_t)pc_;
  uint32_t i = insn_at(pc), op = i & 0x7f;
  if (trace) fprintf(stderr, "[%llu] resolve %08x %08x tgt=%08x mp=%d taken=%d cf=%d bpv=%d\n", (unsigned long long)c.cycles, pc, i, (uint32_t)target, mispredict, taken, cf_type, bp_valid);
  c.res++;
  if (op == 0x63 && taken) c.cond_taken++;
  if (op != 0x63 && op != 0x6f && op != 0x67) c.res_nocf++;
  if (mispredict) {
    c.mp++;
    if (op == 0x63) c.mp_dir++;
    else if (op == 0x67 && cf_type == 4) { if (bp_valid) c.mp_ret_wrong++; else c.mp_ret_nopred++; }
    else if (op == 0x67) { if (bp_valid) c.mp_ind_wrong++; else c.mp_ind_nopred++; }
    else c.mp_other++;
  }
  if (mispredict) {
    // The mispredicted instruction is the last one issued (CVA6 issues nothing
    // younger than an unresolved branch); everything pushed after it is wrong path.
    if (iss_n >= 1 && iss_n <= fe_n && fe_n - (iss_n - 1) <= kRing &&
        fe_ring[(iss_n - 1) % kRing].pc == pc) {
      uint64_t young = fe_n - iss_n, ops = 0;
      for (uint64_t j = iss_n; j < fe_n; j++) ops += fe_ring[j % kRing].ras_op != 0;
      wp_instr[young < kWp ? young : kWp]++;
      wp_rasop[ops < kWp ? ops : kWp]++;
      wp_found++;
    }
  }
  probe_pending = true;
  probe_mp = mispredict != 0;
  probe_t0 = c.cycles;
  probe_t_issue = last_issue_cycle;  // the branch is the last instruction issued
}

void tb_issue() {
  iss_n++;
  if (probe_pending && !(probe_mp && c.cycles == probe_t0)) {
    // (an instruction issued in the resolution cycle of a mispredict is wrong
    // path: flush_unissued clears its functional-unit valid in that cycle)
    uint64_t d = c.cycles - probe_t_issue;
    if (d > kHist) d = kHist;
    (probe_mp ? hist_mp : hist_ok)[d]++;
    probe_pending = false;
  }
  last_issue_cycle = c.cycles;
}

// Wrong-path probe. Every instruction pushed into the instruction queue is
// recorded with the RAS operation the frontend applied for it; the list is
// cleared on every IF flush, and issues are counted from the same point. At a
// misprediction, the entries pushed after the last issued one (the branch) are the wrong-path instructions that
// had entered the queue before the EX redirect, and their RAS operations are
// the wrong-path stack operations a predictor would have to undo.
void tb_fe_push(int pc, int ras_op) {
  fe_ring[fe_n % kRing] = {(uint32_t)pc, (uint8_t)ras_op};
  fe_n++;
}

void tb_fe_flush() { fe_n = 0; iss_n = 0; }

void tb_flush(int kind) { (void)kind; c.flush_ex++; }

void tb_store(int addr_, int data, int be) {
  (void)be;
  uint32_t a = (uint32_t)addr_ & ~3u;
  if (a == tohost_addr + 4) tohost_hi = (uint32_t)data;
  if (a != tohost_addr || done) return;
  if (tohost_hi == 0x01010000u) {
    fputc(data & 0xff, console);
  } else {
    exit_value = (uint32_t)data;
    done = true;
    done_cycle = c.cycles;
  }
}

void tb_hw_counters(long long mcycle, long long minstret) {
  // csr_regfile counts the exit-store commit at the clock edge after it, so the
  // values are taken one cycle later than the snapshot.
  if (snap_hw_pending && c.cycles > snap_cycle) {
    hw_mcycle = (uint64_t)mcycle;
    hw_minstret = (uint64_t)minstret;
    snap_hw_pending = false;
  }
}

}  // extern "C"

namespace {
void hist_stats(const uint64_t *h, uint64_t &n, double &mean, int &mode) {
  n = 0; mean = 0; mode = -1;
  uint64_t best = 0;
  for (int d = 0; d <= kHist; d++) {
    n += h[d];
    mean += (double)d * h[d];
    if (h[d] > best) { best = h[d]; mode = d; }
  }
  if (n) mean /= n;
}
}  // namespace

int main(int argc, char **argv) {
  auto ctx = std::make_unique<VerilatedContext>();
  ctx->commandArgs(argc, argv);
  ctx->randReset(0);  // registers without reset start at 0, reproducibly
  const char *elf = ctx->commandArgsPlusMatch("elf=");
  if (!elf || !*elf) { fprintf(stderr, "usage: %s +elf=<file> [+console=<file>] [+max_cycles=<n>] [+mem_lat=<n>]\n", argv[0]); return 2; }
  std::string elf_path = std::string(elf).substr(5);
  if (!load_elf(elf_path.c_str())) return 2;
  trace = *ctx->commandArgsPlusMatch("trace") != 0;
  const char *con = ctx->commandArgsPlusMatch("console=");
  if (con && *con) {
    console = fopen(std::string(con).substr(9).c_str(), "w");
    if (!console) { perror("console"); return 2; }
  }
  uint64_t max_cycles = 400000000ull;
  const char *mc = ctx->commandArgsPlusMatch("max_cycles=");
  if (mc && *mc) max_cycles = strtoull(std::string(mc).substr(12).c_str(), nullptr, 0);

  auto top = std::make_unique<Vbp55_cva6_tb>(ctx.get());
  top->clk_i = 0;
  top->rst_ni = 0;
  top->eval();
  for (int i = 0; i < 10; i++) { top->clk_i = 1; top->eval(); top->clk_i = 0; top->eval(); }
  top->rst_ni = 1;
  top->eval();
  uint64_t tail = 0;
  while (!ctx->gotFinish() && c.cycles < max_cycles) {
    top->clk_i = 1; top->eval();
    top->clk_i = 0; top->eval();
    if (done && snapped && !snap_hw_pending && ++tail > 2) break;
  }
  top->final();
  if (console != stdout) fclose(console);

  const char *status = !done ? "TIMEOUT" : (snapped && exit_value == 1) ? "PASS" : "FAIL";
  const Counters &s = snapped ? snap : c;
  uint64_t n_mp, n_ok; double mean_mp, mean_ok; int mode_mp, mode_ok;
  hist_stats(hist_mp, n_mp, mean_mp, mode_mp);
  hist_stats(hist_ok, n_ok, mean_ok, mode_ok);
  auto hist_str = [](const uint64_t *h, uint64_t n) {
    std::string r;
    uint64_t last = 0;
    for (uint64_t d = 0; d <= n; d++) if (h[d]) last = d;
    for (uint64_t d = 0; d <= last; d++) r += (d ? ":" : "") + std::to_string(h[d]);
    return r;
  };
  std::string wpi = hist_str(wp_instr, kWp), wpr = hist_str(wp_rasop, kWp);
  printf("BP55CVA6 status=%s exit_value=%u cycles=%llu instret=%llu exceptions=%llu "
         "cond=%llu jal=%llu jal_call=%llu jalr_ret=%llu jalr_call=%llu jalr_ind=%llu cond_taken=%llu "
         "fe_taken_cond=%llu fe_taken_jal=%llu fe_taken_ret=%llu fe_taken_ind=%llu "
         "res=%llu mp=%llu mp_dir=%llu mp_ret_nopred=%llu mp_ret_wrong=%llu mp_ind_nopred=%llu "
         "mp_ind_wrong=%llu mp_other=%llu res_nocf=%llu flush_ex=%llu "
         "pen_n_mp=%llu pen_mode_mp=%d pen_mean_mp=%.3f pen_n_ok=%llu pen_mode_ok=%d pen_mean_ok=%.3f "
         "hw_mcycle=%llu hw_minstret=%llu oob=%llu axi_err=%llu sim_cycles=%llu "
         "wp_found=%llu wp_instr_hist=%s wp_rasop_hist=%s\n",
         status, exit_value, (unsigned long long)s.cycles, (unsigned long long)s.instret,
         (unsigned long long)s.exceptions, (unsigned long long)s.cond, (unsigned long long)s.jal,
         (unsigned long long)s.jal_call, (unsigned long long)s.jalr_ret, (unsigned long long)s.jalr_call,
         (unsigned long long)s.jalr_ind, (unsigned long long)s.cond_taken,
         (unsigned long long)s.fe_taken_cond, (unsigned long long)s.fe_taken_jal,
         (unsigned long long)s.fe_taken_ret, (unsigned long long)s.fe_taken_ind,
         (unsigned long long)s.res, (unsigned long long)s.mp, (unsigned long long)s.mp_dir,
         (unsigned long long)s.mp_ret_nopred, (unsigned long long)s.mp_ret_wrong,
         (unsigned long long)s.mp_ind_nopred, (unsigned long long)s.mp_ind_wrong,
         (unsigned long long)s.mp_other, (unsigned long long)s.res_nocf, (unsigned long long)s.flush_ex,
         (unsigned long long)n_mp, mode_mp, mean_mp, (unsigned long long)n_ok, mode_ok, mean_ok,
         (unsigned long long)hw_mcycle, (unsigned long long)hw_minstret,
         (unsigned long long)oob_accesses, (unsigned long long)axi_errors,
         (unsigned long long)c.cycles, (unsigned long long)wp_found, wpi.c_str(), wpr.c_str());
  return strcmp(status, "PASS") == 0 ? 0 : 1;
}
