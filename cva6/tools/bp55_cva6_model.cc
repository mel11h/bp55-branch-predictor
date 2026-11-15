// Software model of BP55 as integrated in CVA6 (cva6/patches/0005-bp55-predictor.patch,
// option A). Drives sim/bp_model.h (v2 switches pinv=1 tgtfix=1 phrep=1 clr=1, used read-only)
// over a control-flow trace of iss/rvsim with CVA6's prediction rule and training timing:
//   - every fetched instruction is looked up (its PC is known after pre-decode); non-branch PCs
//     are reconstructed from the record gaps as in sim/bpsim.cc, so BTB hits on non-branches
//     (phantoms) are looked up and trained;
//   - pre-decode is the authority on the class: a conditional branch takes BP55's TAGE direction
//     (m.dir, also on a BTB miss) and its target from the immediate, so it mispredicts in EX
//     exactly when m.dir != taken; JAL never mispredicts; a return takes the RAS top; another
//     JALR is predicted only when the BTB hit with an indirect type (target: ITC, else BTB);
//   - the speculative state is BP55's own: history, target history and stack advance only for
//     BTB hits; the frontend repair (CVA6 RTL: one killed fetch) and the EX repair (mispredict)
//     restore it, so after every instruction the speculative state equals BP55's architectural
//     sequence, which is what BP::step applies (GHR shift for a BTB-hit or taken conditional
//     branch, stack by class, target history for indirect jumps). The model counts the
//     frontend repairs with the RTL rule;
//   - training happens in EX: instruction k's update is applied before the lookup of k+D
//     (D = argument, the lookups fired while k travels from the fetch queue to the branch
//     unit), and at once if k mispredicts (younger lookups are refetched after the redirect).
//     Phantom training is applied after the next lookup (the RTL trains it one cycle later).
//   - not modelled: the 64-cycle post-reset clear (lookups and training in it are dropped by the
//     RTL), lookups of wrong-path instructions (their speculative updates are repaired), and the
//     variable fetch-to-EX distance.
// usage: bp55_cva6_model <D> [base_addr] < trace   (prints one line of key=value counts)
#include "../../sim/bp_model.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#pragma pack(push, 1)
struct Rec { uint32_t pc, target; uint16_t gap; uint8_t type, taken; };
#pragma pack(pop)

int main(int argc, char **argv) {
  uint64_t D = argc > 1 ? strtoull(argv[1], 0, 0) : 3;
  uint32_t base = argc > 2 ? strtoul(argv[2], 0, 0) : 0;
  Cfg c; c.LB = 7; c.LBIM = 9; c.LI = 5; c.HT = 6; c.NT = 3; c.LT = 6; c.TT = 7;
  c.hist[0] = 5; c.hist[1] = 12; c.hist[2] = 28;
  c.pinv = 1; c.tgtfix = true; c.phrep = true; c.clr = true;
  c.delay = 1 << 30;              // updates are applied by this driver, not by BP::step
  BP bp(c);
  std::deque<uint64_t> due;       // per pending update in bp.q: index of the first lookup that sees it
  uint64_t idx = 0, nrec = 0, instr = 0;
  uint64_t mp = 0, mp_dir = 0, mp_ret = 0, mp_ind = 0, ferep = 0, phantom = 0, conds = 0;
  auto release = [&](uint64_t upto) {
    while (!due.empty() && due.front() <= upto) { bp.apply(bp.q.front()); bp.q.pop_front(); due.pop_front(); }
  };
  auto flush_all = [&]() { while (!due.empty()) { bp.apply(bp.q.front()); bp.q.pop_front(); due.pop_front(); } };
  // frontend repair rule of the RTL (frontend.sv, bp55_need) for class ty (-1: not control flow)
  auto need = [&](const Meta &m, int ty) {
    int bt = m.btb_hit ? m.btb_type : -1;
    bool sp_cond = bt == T_COND, sp_push = bt == T_CALL || bt == T_ICALL, sp_pop = bt == T_RET;
    bool sp_ind = bt == T_IND || bt == T_ICALL;
    bool o_shift = ty == T_COND && (sp_cond || m.dir), o_push = ty == T_CALL || ty == T_ICALL;
    bool o_pop = ty == T_RET, o_thr = ty == T_IND || ty == T_ICALL;
    bool known = !o_thr || sp_ind;
    return known && (sp_cond != o_shift || sp_push != o_push || sp_pop != o_pop || sp_ind != o_thr);
  };
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
          if (need(pm, -1)) ferep++;
          size_t q0 = bp.q.size();
          bp.step_nonbranch(pc);                 // pushes an update only for a BTB hit (phantom)
          if (bp.q.size() > q0) { phantom++; due.push_back(idx + 1); }
          idx++;
        }
      release(idx);
      Meta m;
      bp.lookup(r.pc, m);
      int ty = r.type;
      bool wrong = false;
      if (ty == T_COND) { conds++; wrong = m.dir != (bool)r.taken; mp_dir += wrong; }
      else if (ty == T_RET) { wrong = m.ras_top != r.target; mp_ret += wrong; }
      else if (ty == T_IND || ty == T_ICALL) {
        bool hit = m.btb_hit && (m.btb_type == T_IND || m.btb_type == T_ICALL);
        uint32_t pred = m.itc_hit ? m.itc_target : m.btb_target;
        wrong = !hit || pred != r.target; mp_ind += wrong;
      }
      if (need(m, ty)) ferep++;
      Meta m2; bp.step(r.pc, r.target, ty, r.taken, m2);   // architectural speculative state + queue the update
      if (wrong) { mp++; due.push_back(idx); flush_all(); }
      else due.push_back(idx + D);
      idx++;
    }
  }
  printf("records=%llu instr=%llu mp=%llu mp_dir=%llu mp_ret=%llu mp_ind=%llu ferep=%llu phantom=%llu conds=%llu\n",
         (unsigned long long)nrec, (unsigned long long)instr, (unsigned long long)mp, (unsigned long long)mp_dir,
         (unsigned long long)mp_ret, (unsigned long long)mp_ind, (unsigned long long)ferep,
         (unsigned long long)phantom, (unsigned long long)conds);
}
