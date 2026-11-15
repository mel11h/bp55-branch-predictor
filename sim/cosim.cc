// RTL (CXXRTL) vs behavioural-model co-simulation.
// usage: cosim <max_records> <delay> <nonbranch 0/1> traces...
#include "bp_model.h"
#include "bp55_rtl.cc"
#include <cstdio>
#include <cstdlib>
#include <string>
#pragma pack(push, 1)
struct Rec { uint32_t pc, target; uint16_t gap; uint8_t type, taken; };
#pragma pack(pop)
using Top = cxxrtl_design::p_bp55;
struct Upd { uint32_t meta[3]; uint32_t pc, tgt; uint8_t type; bool taken, isbr; };
static uint64_t cycles = 0;
static void tick(Top &t) { t.p_clk.set<bool>(true); t.step(); t.p_clk.set<bool>(false); t.step(); cycles++; }
int main(int argc, char **argv) {
  size_t maxr = strtoull(argv[1], 0, 0); int delay = atoi(argv[2]); bool nonbr = atoi(argv[3]);
  uint64_t total = 0, bad = 0, nredir = 0, nphantom = 0;
  for (int a = 4; a < argc; a++) {
    FILE *f = fopen(argv[a], "rb"); fseek(f, 0, SEEK_END); size_t n = ftell(f) / sizeof(Rec); fseek(f, 0, SEEK_SET);
    if (n > maxr) n = maxr;
    std::vector<Rec> tr(n); if (fread(tr.data(), sizeof(Rec), n, f) != n) return 1; fclose(f);
    Cfg c; c.LB = 7; c.LBIM = 9; c.LI = 5; c.HT = 6; c.NT = 3; c.LT = 6; c.TT = 7; c.hist[0] = 5; c.hist[1] = 12; c.hist[2] = 28; c.delay = delay;
    BP bp(c); Meta m; Top t; std::deque<Upd> q;
    t.p_rst__n.set<bool>(false); t.p_clk.set<bool>(false); t.step(); tick(t); t.p_rst__n.set<bool>(true);
    uint64_t tbad = 0;
    auto event = [&](uint32_t pc, bool isbr, int type, bool taken, uint32_t tgt) -> void {
      // cycle A: lookup
      t.p_f__valid.set<bool>(true); t.p_f__pc.set<uint32_t>(pc); t.p_r__valid.set<bool>(false); t.p_u__valid.set<bool>(false);
      t.step();
      bool hit = t.p_f__hit.get<bool>(), dir = t.p_f__dir.get<bool>(), ftk = t.p_f__taken.get<bool>();
      int bt = t.p_f__type.get<uint32_t>(); uint32_t ftg = t.p_f__target.get<uint32_t>();
      Upd u; for (int i = 0; i < 3; i++) u.meta[i] = t.p_f__meta.curr.data[i];
      uint32_t ck[3]; for (int i = 0; i < 3; i++) ck[i] = t.p_f__ckpt.data[i];
      uint32_t rtop = t.p_f__ras__top.get<uint32_t>();
      tick(t);
      // reference model
      bool mhit;
      if (isbr) { bp.step(pc, tgt, type, taken, m); mhit = m.btb_hit; }
      else { uint64_t before = bp.s.phantom; bp.step_nonbranch(pc); mhit = bp.s.phantom != before; if (mhit) bp.lookup(pc, m), nphantom++; }
      bool ok = hit == mhit;
      if (isbr) { ok = ok && dir == m.dir && ftk == m.f1_taken && (!hit || bt == m.btb_type) && (!ftk || ftg == m.f1_tgt) && rtop == m.ras_top; }
      total++; if (!ok) { if (tbad++ < 5) fprintf(stderr, "MISMATCH %s pc=%08x rtl(hit=%d type=%d dir=%d tk=%d tgt=%08x) model(hit=%d type=%d dir=%d tk=%d tgt=%08x)\n", argv[a], pc, hit, bt, dir, ftk, ftg, mhit, m.btb_type, m.dir, m.f1_taken, m.f1_tgt); }
      if (!isbr && !hit) return;
      // cycle B: repair (only if the speculative update was wrong) + training
      bool is_ind = bt == T_IND || bt == T_ICALL;
      bool sp_cond = hit && bt == T_COND, sp_push = hit && (bt == T_CALL || bt == T_ICALL), sp_pop = hit && bt == T_RET, sp_ind = hit && is_ind;
      bool a_shift = isbr && type == T_COND && (sp_cond || taken);
      bool a_push = isbr && (type == T_CALL || type == T_ICALL), a_pop = isbr && type == T_RET, a_thr = isbr && (type == T_IND || type == T_ICALL);
      bool need = sp_cond != a_shift || (a_shift && dir != taken) || sp_push != a_push || sp_pop != a_pop || sp_ind != a_thr || (a_thr && ftg != tgt);
      t.p_f__valid.set<bool>(false);
      if (need) {
        nredir++;
        t.p_r__valid.set<bool>(true); for (int i = 0; i < 3; i++) t.p_r__ckpt.data[i] = ck[i];
        t.p_r__ghr__shift.set<bool>(a_shift); t.p_r__taken.set<bool>(taken); t.p_r__push.set<bool>(a_push); t.p_r__pop.set<bool>(a_pop);
        t.p_r__push__addr.set<uint32_t>(pc + 4); t.p_r__thr__shift.set<bool>(a_thr); t.p_r__target.set<uint32_t>(tgt);
      }
      u.pc = pc; u.tgt = tgt; u.type = type; u.taken = taken; u.isbr = isbr; q.push_back(u);
      if ((int)q.size() > delay) {
        Upd &x = q.front();
        t.p_u__valid.set<bool>(true); t.p_u__isbr.set<bool>(x.isbr); t.p_u__pc.set<uint32_t>(x.pc); t.p_u__type.set<uint32_t>(x.type);
        t.p_u__taken.set<bool>(x.taken); t.p_u__target.set<uint32_t>(x.tgt); for (int i = 0; i < 3; i++) t.p_u__meta.data[i] = x.meta[i];
        q.pop_front();
      }
      t.step(); tick(t);
    };
    for (const Rec &r : tr) {
      if (nonbr && r.gap < 65535) for (uint32_t pc = r.pc - 4 * (r.gap - 1); pc != r.pc; pc += 4) event(pc, false, 0, false, 0);
      event(r.pc, true, r.type, r.taken, r.target);
    }
    bad += tbad;
    fprintf(stderr, "%-40s lookups=%zu mismatches=%llu\n", argv[a], (size_t)total, (unsigned long long)tbad);
  }
  printf("COSIM delay=%d nonbranch=%d: lookups=%llu repairs=%llu phantom=%llu cycles=%llu mismatches=%llu => %s\n", delay, nonbr,
         (unsigned long long)total, (unsigned long long)nredir, (unsigned long long)nphantom, (unsigned long long)cycles, (unsigned long long)bad, bad ? "FAIL" : "PASS");
  return bad != 0;
}
