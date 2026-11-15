// RTL (CXXRTL) vs behavioural-model co-simulation, BP55 v2.
// usage: cosim [-n max_records (0 = all)] [-d delay] [-b nonbranch 0/1] [-s stall_permille]
//              [-m misstrain_permille] [-f flush_per_100k] [-r remap 0/1] [-S seed] traces...
//
// Per trace, in one fresh RTL instance:
//  1. every RTL state element (registers and table memories) is filled with random bits, then reset
//     is applied; during the post-reset clear (f_busy) random lookups, redirects and training
//     messages are driven and the outputs must be the forced fall-through values; when f_busy
//     drops (after exactly 64 cycles) every cleared table and register must be zero / reset value.
//     BTB / ITC payloads stay random (they are guarded by their valid bits).
//  2. every instruction of the trace (branches and, with -b 1, every non-branch PC) is looked up.
//     With probability stall_permille the lookup is first held in IF1 for 1-3 cycles with
//     f_fire = 0. In every held cycle and in the f_fire cycle ALL outputs (f_hit, f_type, f_taken,
//     f_target when taken, f_dir, f_ras_top, f_meta, f_ckpt) are compared against the model.
//  3. with probability flush_per_100k the accepted lookup is undone by a flush (r_fire with no
//     history / stack operation, restoring its own f_ckpt) and looked up again: it must give the
//     same outputs.
//  4. the next cycle carries the ID/EX repair (when the speculative update was wrong) and the
//     training message (delayed by `delay` messages); a non-branch whose lookup missed the BTB gets
//     a u_isbr = 0 training message with probability misstrain_permille (it must have no effect).
//  The model is bp_model.h with pinv = tgtfix = 1 (the v2 behaviour of rtl/bp55.sv).
#include "bp_model.h"
#include "bp55_rtl.cc"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#pragma pack(push, 1)
struct Rec { uint32_t pc, target; uint16_t gap; uint8_t type, taken; };
#pragma pack(pop)
using Top = cxxrtl_design::p_bp55;

// raw chunk access for wide ports (value<> or wire<>)
template <size_t N> static const uint32_t *rd(const cxxrtl::value<N> &v) { return v.data; }
template <size_t N> static const uint32_t *rd(const cxxrtl::wire<N> &w) { return w.curr.data; }
template <size_t N> static uint32_t *wr(cxxrtl::value<N> &v) { return v.data; }
template <size_t N> static uint32_t *wr(cxxrtl::wire<N> &w) { return w.next.data; }

struct Rng { uint64_t s; uint32_t operator()() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return (uint32_t)(s >> 11); } };

struct Bits { uint32_t w[4] = {0, 0, 0, 0}; int n = 0;
  void put(uint64_t v, int k) { for (int i = 0; i < k; i++, n++) if ((v >> i) & 1) w[n >> 5] |= 1u << (n & 31); } };

struct Exp { bool hit, dir, taken; uint32_t type, target, ras_top; uint32_t meta[4], ckpt[3]; };

int main(int argc, char **argv) {
  size_t maxr = 0; int delay = 0; bool nonbr = true; uint32_t stall_pm = 100, miss_pm = 1000, flush_pk = 50; bool remap = false;
  uint64_t seed = 1;
  int o;
  while ((o = getopt(argc, argv, "n:d:b:s:m:f:r:S:")) != -1) {
    switch (o) {
    case 'n': maxr = strtoull(optarg, 0, 0); break; case 'd': delay = atoi(optarg); break;
    case 'b': nonbr = atoi(optarg); break; case 's': stall_pm = atoi(optarg); break;
    case 'm': miss_pm = atoi(optarg); break; case 'f': flush_pk = atoi(optarg); break;
    case 'r': remap = atoi(optarg); break; case 'S': seed = strtoull(optarg, 0, 0); break;
    default: fprintf(stderr, "bad option\n"); return 2;
    }
  }
  uint64_t g_bad = 0;
  for (int a = optind; a < argc; a++) {
    FILE *f = fopen(argv[a], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[a]); return 2; }
    fseek(f, 0, SEEK_END); size_t n = ftell(f) / sizeof(Rec); fseek(f, 0, SEEK_SET);
    if (maxr && n > maxr) n = maxr;
    std::vector<Rec> tr(n);
    if (fread(tr.data(), sizeof(Rec), n, f) != n) { fprintf(stderr, "short read %s\n", argv[a]); return 2; }
    fclose(f);
    std::string tn = argv[a]; tn = tn.substr(tn.rfind('/') + 1);
    Rng rng{seed * 0x9E3779B97F4A7C15ull ^ std::hash<std::string>()(tn) ^ 0x1234567ull}; rng(); rng();

    Cfg c; c.LB = 7; c.LBIM = 9; c.LI = 5; c.HT = 6; c.NT = 3; c.LT = 6; c.TT = 7; c.hist[0] = 5; c.hist[1] = 12; c.hist[2] = 28;
    c.delay = delay; c.pinv = true; c.tgtfix = true;
    BP bp(c); Top t;
    struct Upd { uint32_t meta[4]; uint32_t pc, tgt; uint8_t type; bool taken, isbr; };
    std::deque<Upd> q;
    uint64_t bad = 0, cyc = 0;
    uint64_t n_look = 0, n_br = 0, n_stall = 0, n_cmp = 0, n_flush = 0, n_miss = 0, n_phantom = 0, n_repair = 0, n_far = 0, n_upd = 0;
    auto tick = [&]() { t.p_clk.set<bool>(true); t.step(); t.p_clk.set<bool>(false); t.step(); cyc++; };
    auto fail = [&](const char *what, uint32_t pc) { if (bad++ < 8) fprintf(stderr, "MISMATCH %s %s pc=%08x cycle=%llu\n", tn.c_str(), what, pc, (unsigned long long)cyc); };
    auto idle_inputs = [&]() {
      t.p_f__fire.set<bool>(false); t.p_r__fire.set<bool>(false); t.p_u__fire.set<bool>(false);
      t.p_r__ghr__shift.set<bool>(false); t.p_r__taken.set<bool>(false); t.p_r__push.set<bool>(false);
      t.p_r__pop.set<bool>(false); t.p_r__thr__shift.set<bool>(false);
    };

    // ---------------- 1. random initial state, reset, post-reset clear ----------------
    cxxrtl::debug_items items; t.debug_info(&items, /*scopes=*/nullptr, "");
    for (auto &kv : items.table) for (auto &it : kv.second) {
      if (it.flags & cxxrtl::debug_item::INPUT) continue;
      if (it.type != cxxrtl::debug_item::WIRE && it.type != cxxrtl::debug_item::MEMORY) continue;
      size_t ch = (it.width + 31) / 32;
      for (size_t i = 0; i < ch * it.depth; i++) {
        uint32_t v = rng();
        if (i % ch == ch - 1 && it.width % 32) v &= (1u << (it.width % 32)) - 1;
        it.curr[i] = v; if (it.type == cxxrtl::debug_item::WIRE && it.next) it.next[i] = v;
      }
    }
    idle_inputs(); t.p_f__pc.set<uint32_t>(rng());
    t.p_rst__n.set<bool>(false); t.p_clk.set<bool>(false); t.step(); tick(); tick(); t.p_rst__n.set<bool>(true); t.step();
    uint64_t busy_cycles = 0;
    while (t.p_f__busy.get<bool>() && busy_cycles < 10000) {
      // random traffic: must be ignored, outputs forced
      t.p_f__pc.set<uint32_t>(rng() & ~3u); t.p_f__fire.set<bool>(rng() & 1);
      t.p_r__fire.set<bool>(rng() & 1); for (int i = 0; i < 3; i++) wr(t.p_r__ckpt)[i] = rng() & (i == 2 ? 7u : ~0u);
      t.p_r__ghr__shift.set<bool>(rng() & 1); t.p_r__push.set<bool>(rng() & 1); t.p_r__pop.set<bool>(rng() & 1);
      t.p_r__thr__shift.set<bool>(rng() & 1); t.p_r__push__addr.set<uint32_t>(rng()); t.p_r__target.set<uint32_t>(rng());
      t.p_u__fire.set<bool>(rng() & 1); t.p_u__isbr.set<bool>(rng() & 1); t.p_u__pc.set<uint32_t>(rng()); t.p_u__type.set<uint32_t>(rng() % 6);
      t.p_u__taken.set<bool>(rng() & 1); t.p_u__target.set<uint32_t>(rng()); for (int i = 0; i < 4; i++) wr(t.p_u__meta)[i] = rng() & (i == 3 ? 0xFFu : ~0u);
      t.step();
      if (t.p_f__hit.get<bool>() || t.p_f__taken.get<bool>() || t.p_f__dir.get<bool>() || t.p_f__type.get<uint32_t>() || t.p_f__ras__top.get<uint32_t>())
        fail("busy-outputs-not-forced", 0);
      tick(); busy_cycles++;
    }
    idle_inputs(); t.step();
    if (busy_cycles != 64) fail("busy-length", (uint32_t)busy_cycles);
    {
      // every cleared / reset element must now be zero (use_alt: 8); BTB / ITC payloads stay random
      static const char *zero[] = {"bim", "tctr0", "tctr1", "tctr2", "ttag0", "ttag1", "ttag2", "tu0", "tu1", "tu2", "ras",
                                   "ghr", "thr", "rasp", "rstcnt", "btb_v", "itc_v"};
      for (const char *nm : zero) {
        if (!items.table.count(nm)) { fail("clear-item-missing", 0); fprintf(stderr, "  no debug item %s\n", nm); continue; }
        for (auto &it : items.table.at(nm)) {
          size_t ch = (it.width + 31) / 32;
          for (size_t i = 0; i < ch * it.depth; i++) if (it.curr[i]) { fail("not-cleared", 0); fprintf(stderr, "  %s word %zu = %08x\n", nm, i, it.curr[i]); break; }
        }
      }
      if (!items.table.count("use_alt") || items.table.at("use_alt")[0].curr[0] != 8) fail("use_alt-reset", 0);
    }

    // ---------------- 2-4. trace-driven lookups ----------------
    auto check = [&](const Exp &e, uint32_t pc) {
      n_cmp++;
      bool hit = t.p_f__hit.get<bool>(), tk = t.p_f__taken.get<bool>();
      if (t.p_f__busy.get<bool>()) fail("busy", pc);
      if (hit != e.hit) fail("f_hit", pc);
      if (t.p_f__type.get<uint32_t>() != e.type) fail("f_type", pc);
      if (t.p_f__dir.get<bool>() != e.dir) fail("f_dir", pc);
      if (tk != e.taken) fail("f_taken", pc);
      if (tk && t.p_f__target.get<uint32_t>() != e.target) fail("f_target", pc);
      if (t.p_f__ras__top.get<uint32_t>() != e.ras_top) fail("f_ras_top", pc);
      const uint32_t *mm = rd(t.p_f__meta), *ck = rd(t.p_f__ckpt);
      for (int i = 0; i < 4; i++) if (mm[i] != e.meta[i]) { fail("f_meta", pc); if (bad <= 8) fprintf(stderr, "  meta[%d] rtl=%08x model=%08x\n", i, mm[i], e.meta[i]); break; }
      for (int i = 0; i < 3; i++) if (ck[i] != e.ckpt[i]) { fail("f_ckpt", pc); if (bad <= 8) fprintf(stderr, "  ckpt[%d] rtl=%08x model=%08x\n", i, ck[i], e.ckpt[i]); break; }
    };
    auto event = [&](uint32_t pc, bool isbr, int type, bool taken, uint32_t tgt) {
      // reference: pure model lookup and the packed meta / checkpoint the RTL must produce
      Meta m; bp.lookup(pc, m); Exp e;
      e.hit = m.btb_hit; e.type = m.btb_hit ? m.btb_type : 0; e.dir = m.dir; e.ras_top = m.ras_top;
      bp.predict(m, e.taken, e.target);
      uint32_t ind = m.itc_hit ? m.itc_target >> 2 : m.btb_hit ? m.btb_target >> 2 : (pc >> 20) << 18;
      Bits mb; mb.put(m.btb_hit, 1); mb.put(e.type, 3); mb.put(ind, 30); mb.put(m.itc_idx, 5); mb.put(m.itc_tag, 8); mb.put(m.bim, 2);
      for (int i = 0; i < 3; i++) mb.put(m.idx[i], 6);
      for (int i = 0; i < 3; i++) mb.put(m.tag[i], 7);
      for (int i = 0; i < 3; i++) mb.put(m.ctr[i], 3);
      for (int i = 0; i < 3; i++) mb.put(m.u[i], 1);
      for (int i = 0; i < 3; i++) mb.put(m.hit[i], 1);
      mb.put(m.dir, 1);
      Bits cb; cb.put(bp.ghr & ((1u << 28) - 1), 28); cb.put(bp.thr, 6); cb.put(bp.rasp, 3); cb.put(m.ras_top >> 2, 30);
      memcpy(e.meta, mb.w, sizeof e.meta); memcpy(e.ckpt, cb.w, sizeof e.ckpt);
      // IF1: optional stall, then fire
      idle_inputs(); t.p_f__pc.set<uint32_t>(pc);
      if (rng() % 1000 < stall_pm) {
        int k = 1 + rng() % 3;
        for (int i = 0; i < k; i++) { t.step(); check(e, pc); tick(); n_stall++; }
      }
      t.p_f__fire.set<bool>(true); t.step(); check(e, pc);
      bool hit = t.p_f__hit.get<bool>(), dir = t.p_f__dir.get<bool>();
      int bt = t.p_f__type.get<uint32_t>(); uint32_t ftg = t.p_f__target.get<uint32_t>();
      Upd u; memcpy(u.meta, rd(t.p_f__meta), sizeof u.meta);
      uint32_t ck[3]; memcpy(ck, rd(t.p_f__ckpt), sizeof ck);
      tick(); n_look++;
      if (flush_pk && rng() % 100000 < flush_pk) {
        // trap / interrupt style flush back to this instruction, then fetch it again
        idle_inputs(); t.p_f__pc.set<uint32_t>(rng() & ~3u); t.p_r__fire.set<bool>(true);
        for (int i = 0; i < 3; i++) wr(t.p_r__ckpt)[i] = ck[i];
        t.step(); tick(); idle_inputs();
        t.p_f__pc.set<uint32_t>(pc); t.p_f__fire.set<bool>(true); t.step(); check(e, pc); tick(); n_flush++;
      }
      // advance the model
      bool phantom = false;
      if (isbr) { Meta m2; bp.step(pc, tgt, type, taken, m2); n_br++; if ((type == T_COND || type == T_JUMP || type == T_CALL) && ((pc ^ tgt) >> 20)) n_far++; }
      else { phantom = m.btb_hit; bp.step_nonbranch(pc); n_phantom += phantom; }
      // ID/EX: repair (only if the speculative update was wrong) + training
      idle_inputs(); t.p_f__pc.set<uint32_t>(rng() & ~3u);
      bool any = false;
      if (isbr || phantom) {
        bool is_ind = bt == T_IND || bt == T_ICALL;
        bool sp_cond = hit && bt == T_COND, sp_push = hit && (bt == T_CALL || bt == T_ICALL), sp_pop = hit && bt == T_RET, sp_ind = hit && is_ind;
        bool a_shift = isbr && type == T_COND && (sp_cond || taken);
        bool a_push = isbr && (type == T_CALL || type == T_ICALL), a_pop = isbr && type == T_RET, a_thr = isbr && (type == T_IND || type == T_ICALL);
        bool need = sp_cond != a_shift || (a_shift && dir != taken) || sp_push != a_push || sp_pop != a_pop || sp_ind != a_thr || (a_thr && ftg != tgt);
        if (need) {
          n_repair++; any = true;
          t.p_r__fire.set<bool>(true); for (int i = 0; i < 3; i++) wr(t.p_r__ckpt)[i] = ck[i];
          t.p_r__ghr__shift.set<bool>(a_shift); t.p_r__taken.set<bool>(taken); t.p_r__push.set<bool>(a_push); t.p_r__pop.set<bool>(a_pop);
          t.p_r__push__addr.set<uint32_t>(pc + 4); t.p_r__thr__shift.set<bool>(a_thr); t.p_r__target.set<uint32_t>(tgt);
        }
        u.pc = pc; u.tgt = tgt; u.type = type; u.taken = taken; u.isbr = isbr; q.push_back(u);
        if ((int)q.size() > delay) {
          Upd &x = q.front(); any = true; n_upd++;
          t.p_u__fire.set<bool>(true); t.p_u__isbr.set<bool>(x.isbr); t.p_u__pc.set<uint32_t>(x.pc); t.p_u__type.set<uint32_t>(x.type);
          t.p_u__taken.set<bool>(x.taken); t.p_u__target.set<uint32_t>(x.tgt); for (int i = 0; i < 4; i++) wr(t.p_u__meta)[i] = x.meta[i];
          q.pop_front();
        }
      } else if (miss_pm && rng() % 1000 < miss_pm) {
        // non-branch that missed: an (unneeded) u_isbr = 0 message must not evict anything
        any = true; n_miss++;
        t.p_u__fire.set<bool>(true); t.p_u__isbr.set<bool>(false); t.p_u__pc.set<uint32_t>(pc); t.p_u__type.set<uint32_t>(rng() % 6);
        t.p_u__taken.set<bool>(rng() & 1); t.p_u__target.set<uint32_t>(rng()); for (int i = 0; i < 4; i++) wr(t.p_u__meta)[i] = u.meta[i];
      }
      if (any) { t.step(); tick(); }
    };
    for (Rec r : tr) {
      if (remap) { r.pc = remap_addr(r.pc); r.target = remap_addr(r.target); }
      if (nonbr && r.gap < 65535) for (uint32_t pc = r.pc - 4 * (r.gap - 1); pc != r.pc; pc += 4) event(pc, false, 0, false, 0);
      event(r.pc, true, r.type, r.taken, r.target);
    }
    g_bad += bad;
    printf("TRACE %s records=%zu lookups=%llu branches=%llu held_cycles=%llu compares=%llu flushes=%llu miss_train=%llu "
           "phantom=%llu far_direct=%llu repairs=%llu updates=%llu busy=%llu cycles=%llu mismatches=%llu\n",
           tn.c_str(), n, (unsigned long long)n_look, (unsigned long long)n_br, (unsigned long long)n_stall, (unsigned long long)n_cmp,
           (unsigned long long)n_flush, (unsigned long long)n_miss, (unsigned long long)n_phantom, (unsigned long long)n_far,
           (unsigned long long)n_repair, (unsigned long long)n_upd, (unsigned long long)busy_cycles, (unsigned long long)cyc, (unsigned long long)bad);
    fflush(stdout);
  }
  return g_bad != 0;
}
