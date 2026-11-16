// Cycle-by-cycle replay of a recorded BP55 stimulus (cg/act/mkrecorder.py) on a Verilated gate
// netlist, with output comparison against the recorded RTL outputs and optional SAIF output.
//
// usage: replay <record file> [<saif out> <first cycle> <last cycle> <period ps>]
//   Every record is one clock cycle: inputs are applied while clk is low (time i*P), outputs are
//   compared after the design settles, the clock rises at i*P + P/2. With a SAIF file, switching
//   activity is recorded for cycles [first, last) only (the cycles before it warm the predictor up);
//   SAIF time 0 is the start of cycle <first>, so DURATION is the window length.
// Prints a REPLAY line: cycles, compared, mismatches per output field; exit 1 on any mismatch
// except f_target while f_taken = 0 (reported separately; the co-simulation does not check it).
#include "Vbp55.h"
#include "verilated.h"
#if VM_TRACE_SAIF
#include "verilated_saif_c.h"
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

int main(int argc, char **argv) {
  if (argc != 2 && argc != 6) { fprintf(stderr, "usage: replay rec [saif first last period_ps]\n"); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  fseek(f, 0, SEEK_END); size_t n = ftell(f) / 96; fseek(f, 0, SEEK_SET);
  std::vector<uint32_t> r(n * 24);
  if (fread(r.data(), 96, n, f) != n) { fprintf(stderr, "short read\n"); return 2; }
  fclose(f);
  VerilatedContext ctx;
  Vbp55 top(&ctx);
  uint64_t first = 0, last = 0, P = 6000;
  const char *saif = nullptr;
  if (argc == 6) { saif = argv[2]; first = strtoull(argv[3], 0, 0); last = strtoull(argv[4], 0, 0); P = strtoull(argv[5], 0, 0); }
#if VM_TRACE_SAIF
  VerilatedSaifC *tfp = nullptr;
  if (saif) { ctx.traceEverOn(true); tfp = new VerilatedSaifC; top.trace(tfp, 99); }
#else
  if (saif) { fprintf(stderr, "built without --trace-saif\n"); return 2; }
#endif
  const char *field[] = {"f_busy", "f_hit", "f_taken", "f_dir", "f_type", "f_target", "f_ras_top", "f_meta", "f_ckpt", "f_target(not taken)"};
  uint64_t mm[10] = {0}, ncmp = 0, shown = 0;
  bool tracing = false;
  // rst_n starts high, so that the first record (rst_n = 0) asserts reset with an edge: async-reset
  // flops behind an ICG see no clock edge during reset, and a level that is already low at time 0
  // is not an event in the Verilated model (nor in an event-driven simulator)
  top.clk = 0; top.rst_n = 1; top.eval();
  for (size_t i = 0; i < n; i++) {
    const uint32_t *w = &r[i * 24];
    top.f_pc = w[0]; top.r_push_addr = w[1]; top.r_target = w[2]; top.u_pc = w[3]; top.u_target = w[4];
    for (int k = 0; k < 3; k++) top.r_ckpt[k] = w[5 + k];
    for (int k = 0; k < 4; k++) top.u_meta[k] = w[8 + k];
    uint32_t c = w[12];
    top.f_fire = c & 1; top.r_fire = c >> 1 & 1; top.r_ghr_shift = c >> 2 & 1; top.r_taken = c >> 3 & 1;
    top.r_push = c >> 4 & 1; top.r_pop = c >> 5 & 1; top.r_thr_shift = c >> 6 & 1; top.u_fire = c >> 7 & 1;
    top.u_isbr = c >> 8 & 1; top.u_taken = c >> 9 & 1; top.rst_n = c >> 10 & 1; top.u_type = c >> 16 & 7;
    top.clk = 0;
    top.eval();
#if VM_TRACE_SAIF
    if (tfp && i == first) { tfp->open(saif); tracing = true; }
    if (tracing && i == last) { tfp->dump((i - first) * P); tfp->close(); tracing = false; }
    if (tracing) tfp->dump((i - first) * P);
#endif
    // compare
    ncmp++;
    uint32_t o = w[23];
    bool bad[10] = {false};
    bad[0] = top.f_busy != (o & 1); bad[1] = top.f_hit != (o >> 1 & 1); bad[2] = top.f_taken != (o >> 2 & 1);
    bad[3] = top.f_dir != (o >> 3 & 1); bad[4] = top.f_type != (o >> 4 & 7);
    if (top.f_target != w[14]) { if (o >> 2 & 1) bad[5] = true; else bad[9] = true; }
    bad[6] = top.f_ras_top != w[15];
    for (int k = 0; k < 4; k++) if (top.f_meta[k] != w[16 + k]) bad[7] = true;
    for (int k = 0; k < 3; k++) if (top.f_ckpt[k] != w[20 + k]) bad[8] = true;
    for (int k = 0; k < 10; k++) if (bad[k]) {
      mm[k]++;
      if (k != 9 && shown++ < 10) fprintf(stderr, "MISMATCH cycle %zu %s\n", i, field[k]);
    }
    top.clk = 1;
    top.eval();
#if VM_TRACE_SAIF
    if (tracing) tfp->dump((i - first) * P + P / 2);
#endif
  }
#if VM_TRACE_SAIF
  if (tracing) { top.clk = 0; top.eval(); tfp->dump((n - first) * P); tfp->close(); }
#endif
  uint64_t tot = 0;
  printf("REPLAY cycles=%zu compared=%llu", n, (unsigned long long)ncmp);
  for (int k = 0; k < 10; k++) { printf(" %s=%llu", field[k], (unsigned long long)mm[k]); if (k != 9) tot += mm[k]; }
  printf(" => %s\n", tot ? "FAIL" : "PASS");
  if (saif) printf("SAIF %s cycles %llu..%llu period %llu ps\n", saif, (unsigned long long)first, (unsigned long long)last, (unsigned long long)P);
  return tot ? 1 : 0;
}
