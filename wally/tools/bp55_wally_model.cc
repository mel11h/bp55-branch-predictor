// Software model of BP55 as integrated in CORE-V Wally (wally/patches/0002-bpred-bp55.patch).
// Drives sim/bp_model.h (v2 switches pinv=1 tgtfix=1 phrep=1, used read-only) over a control-flow
// trace of iss/rvsim, with Wally's redirect rule and Wally's training timing instead of bpsim's:
//   - every lookup is verified in E against the full next PC; there is no Decode-stage prediction,
//     so a conditional branch that misses the BTB is fetched fall-through (f_taken = 0) and costs a
//     redirect only if it was taken;
//   - in addition an instruction whose speculative history / stack / target-history update was wrong
//     redirects although its next PC was right ("need", same rule as sim/cosim.cc);
//   - training happens in E: instruction k's update is applied after the lookups of k+1 and k+2
//     (in D and F) and before the lookup of k+3; if k redirects, before the next (correct-path)
//     lookup. Load-use and other D-only stalls, which let a held F lookup see one more update, are
//     not modelled.
// Non-branch PCs are reconstructed from the record gaps as in sim/bpsim.cc, so BTB hits on
// non-branches (phantoms) are looked up and trained.
// usage: bp55_wally_model [base_addr] < trace   (prints one CSV line: counts)
#include "../../sim/bp_model.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#pragma pack(push, 1)
struct Rec { uint32_t pc, target; uint16_t gap; uint8_t type, taken; };
#pragma pack(pop)

int main(int argc, char **argv) {
  uint32_t base = argc > 1 ? strtoul(argv[1], 0, 0) : 0;
  Cfg c; c.LB = 7; c.LBIM = 9; c.LI = 5; c.HT = 6; c.NT = 3; c.LT = 6; c.TT = 7;
  c.hist[0] = 5; c.hist[1] = 12; c.hist[2] = 28;
  c.pinv = 1; c.tgtfix = true; c.phrep = true; c.clr = true;
  c.delay = 1 << 30;              // updates are applied by this driver, not by BP::step
  BP bp(c);
  std::deque<uint64_t> due;       // per pending update in bp.q: index of the first lookup that sees it
  uint64_t idx = 0, redirects = 0, pcwrong = 0, needonly = 0, phantom = 0, phantom_redir = 0, dirwrong = 0, conds = 0;
  uint64_t instr = 0, nrec = 0;
  auto release = [&](uint64_t upto) {   // apply every pending update due at or before lookup `upto`
    while (!due.empty() && due.front() <= upto) { bp.apply(bp.q.front()); bp.q.pop_front(); due.pop_front(); }
  };
  auto flush_all = [&]() { while (!due.empty()) { bp.apply(bp.q.front()); bp.q.pop_front(); due.pop_front(); } };
  std::vector<Rec> buf(1 << 16);
  size_t n;
  while ((n = fread(buf.data(), sizeof(Rec), buf.size(), stdin)) > 0) {
    for (size_t i = 0; i < n; i++) {
      Rec r = buf[i]; r.pc += base; r.target += base; nrec++;
      instr += r.gap;
      if (r.gap < 65535)
        for (uint32_t pc = r.pc - 4 * (r.gap - 1); pc != r.pc; pc += 4) {
          release(idx);
          Meta pm; bp.lookup(pc, pm);
          bool ptk = pm.btb_hit && (pm.btb_type == T_COND ? pm.dir : true);
          size_t q0 = bp.q.size();
          int cost = bp.step_nonbranch(pc);      // pushes an update only for a BTB hit (phantom)
          if (bp.q.size() > q0) {
            phantom++;
            // a phantom hit always redirects in Wally: predicted taken (wrong next PC) or a
            // speculative update that must be undone (phrep = 1 makes cost 2 in both cases)
            if (cost) { phantom_redir++; redirects++; pcwrong += ptk; needonly += !ptk; due.push_back(idx); flush_all(); }
            else due.push_back(idx + 3);
          }
          idx++;
        }
      release(idx);
      Meta m;
      bp.lookup(r.pc, m);                         // what F sees (step() repeats the same lookup)
      bool f1_taken; uint32_t f1_tgt; bp.predict(m, f1_taken, f1_tgt);
      uint32_t actual = r.taken ? r.target : r.pc + 4;
      uint32_t f1_next = f1_taken ? f1_tgt : r.pc + 4;
      int bt = m.btb_hit ? m.btb_type : -1;
      bool is_ind = bt == T_IND || bt == T_ICALL;
      bool sp_cond = bt == T_COND, sp_push = bt == T_CALL || bt == T_ICALL, sp_pop = bt == T_RET, sp_ind = is_ind;
      int ty = r.type;
      bool a_shift = ty == T_COND && (sp_cond || r.taken);
      bool a_push = ty == T_CALL || ty == T_ICALL, a_pop = ty == T_RET, a_thr = ty == T_IND || ty == T_ICALL;
      bool need = sp_cond != a_shift || (a_shift && m.dir != (bool)r.taken) || sp_push != a_push || sp_pop != a_pop ||
                  sp_ind != a_thr || (a_thr && f1_tgt != r.target);
      bool wrong = f1_next != actual;
      if (ty == T_COND) { conds++; dirwrong += m.dir != (bool)r.taken; }
      Meta m2; bp.step(r.pc, r.target, ty, r.taken, m2);   // speculative state + queue the update
      if (wrong || need) {
        redirects++; pcwrong += wrong; needonly += !wrong;
        due.push_back(idx); flush_all();
      } else due.push_back(idx + 3);
      idx++;
    }
  }
  printf("records=%llu instr=%llu redirects=%llu pc_wrong=%llu need_only=%llu phantom=%llu phantom_redirects=%llu conds=%llu dir_wrong=%llu\n",
         (unsigned long long)nrec, (unsigned long long)instr, (unsigned long long)redirects, (unsigned long long)pcwrong,
         (unsigned long long)needonly, (unsigned long long)phantom, (unsigned long long)phantom_redir,
         (unsigned long long)conds, (unsigned long long)dirwrong);
}
