// BP55: bit-accurate behavioural model of the branch prediction unit.
// The RTL in ../rtl mirrors this file 1:1 (same hashes, same update rules).
// Default Cfg = v1 behaviour (reproduces results/final.csv). rtl/bp55.sv (v2)
// corresponds to pinv=1 tgtfix=1 (clr only adds the clear-sequencer bits to bits(),
// phrep only changes the cycle accounting); "v2=1" sets all four.
#pragma once
#include <cstdint>
#include <cstring>
#include <deque>
#include <vector>

enum { T_COND = 0, T_JUMP = 1, T_CALL = 2, T_RET = 3, T_IND = 4, T_ICALL = 5 };
enum { K_NT = 0, K_BIMODAL = 1, K_GSHARE = 2, K_TAGE = 3 };
#define MAXT 6

struct Cfg {
  int kind = K_TAGE;
  int LB = 6, TBB = 8, TW = 18;       // BTB: log2 entries, tag bits, stored target bits ([TW+1:2])
  int LR = 3;                         // RAS: log2 depth (LR<0: no RAS)
  int LBIM = 7;                       // bimodal / gshare table: log2 entries
  int HG = 8;                         // gshare history length
  int NT = 3, LT = 6, TT = 8, UB = 1; // TAGE: tables, log2 entries, tag bits, useful bits
  int hist[MAXT] = {5, 12, 28, 0, 0, 0};
  int LRST = 11;                      // u-bit reset period (log2 conditional updates)
  int LI = 0, TI = 8, HT = 12;        // indirect target cache: log2 entries (0: none), tag bits, target-history bits
  int delay = 0;                      // table-update delay in branches (pipeline latency)
  bool phantom = true;                // model BTB lookups of non-branch PCs
  bool allhist = false;               // idealised: every conditional branch enters the history
  bool nobtb = false;                 // no BTB at all (decode-time redirect only)
  // ---- v2 switches (all false = v1) ----
  int pinv = 0;         // B: 1 = an invalidating training message (phantom / type change) acts only
                        //    if the lookup hit and the entry still carries the same tag (= RTL v2);
                        //    2 = evaluation only (no RTL): gate on the lookup's hit bit alone
  bool tgtfix = false;  // E: ITC stores the full 30-bit target; a direct branch whose target lies
                        //    outside its 2^(TW+2)-byte region is not stored in the BTB
  bool phrep = false;   // F: a phantom BTB hit always costs a decode redirect (2 cycles): either
                        //    fetch went wrong or the speculative GHR / RAS / THR must be repaired
  bool clr = false;     // C: count the post-reset clear sequencer (busy + row counter) in bits()
  int itw() const { return tgtfix ? 30 : TW; }
  int lclr() const { int l = LBIM - 3; if (kind == K_TAGE && LT > l) l = LT; if (LR > l) l = LR; return l; }
  int bits() const {
    int b = 0;
    if (!nobtb) b += (1 << LB) * (1 + TBB + 3 + TW);
    if (LR >= 0) b += (1 << LR) * 30 + LR;
    if (kind == K_BIMODAL) b += (1 << LBIM) * 2;
    if (kind == K_GSHARE) b += (1 << LBIM) * 2 + HG;
    if (kind == K_TAGE) { b += (1 << LBIM) * 2 + NT * (1 << LT) * (TT + 3 + UB) + hist[NT - 1] + 4 + LRST; }
    if (LI) b += (1 << LI) * (1 + TI + itw()) + HT;
    if (clr) b += lclr() + 1;
    return b;
  }
};

struct Meta {
  uint32_t pc; uint64_t ghr; uint32_t thr;
  bool btb_hit; uint8_t btb_type; uint32_t btb_target;
  bool itc_hit; uint32_t itc_idx, itc_tag, itc_target;
  uint32_t ras_top;
  uint32_t bim_idx; uint8_t bim;
  uint32_t idx[MAXT], tag[MAXT]; uint8_t ctr[MAXT], u[MAXT]; bool hit[MAXT];
  int prov, alt; bool prov_pred, alt_pred, weak, dir;
  bool f1_taken; uint32_t f1_tgt;
};

struct Stats {
  uint64_t instr = 0, br[6] = {0}, cond_taken = 0;
  uint64_t dir_wrong = 0;          // conditional direction mispredicts
  uint64_t mis[6] = {0};           // EX-resolved mispredicts per type (cost 3)
  uint64_t idr[6] = {0};           // decode redirects per type (cost 2)
  uint64_t phantom = 0;
  uint64_t taken_cf = 0, taken_hit0 = 0; // taken control flow, of which zero-bubble
  uint64_t slow_diff = 0;          // F1(bimodal) vs F2(TAGE) disagreement on BTB-hit conditionals
};

static inline uint32_t fold(uint64_t h, int L, int w) {
  if (L < 64) h &= (1ull << L) - 1;
  uint32_t r = 0, m = (1u << w) - 1;
  while (h) { r ^= (uint32_t)h & m; h >>= w; }
  return r;
}

struct BP {
  Cfg c;
  struct BtbE { bool v; uint32_t tag; uint8_t type; uint32_t tgt; };
  struct ItcE { bool v; uint32_t tag; uint32_t tgt; };
  std::vector<BtbE> btb; std::vector<ItcE> itc;
  std::vector<uint8_t> bim; std::vector<uint8_t> tctr[MAXT], tu[MAXT]; std::vector<uint32_t> ttag[MAXT];
  std::vector<uint32_t> ras; uint32_t rasp = 0;
  uint64_t ghr = 0; uint32_t thr = 0; uint32_t use_alt = 8, rstcnt = 0;
  struct Pend { Meta m; uint8_t type; bool taken; uint32_t tgt; bool isbr; };
  std::deque<Pend> q;
  Stats s;

  explicit BP(const Cfg &cfg) : c(cfg) {
    btb.assign(1u << c.LB, BtbE{false, 0, 0, 0});
    itc.assign(1u << c.LI, ItcE{false, 0, 0});
    bim.assign(1u << c.LBIM, 0);
    for (int i = 0; i < c.NT; i++) { tctr[i].assign(1u << c.LT, 0); tu[i].assign(1u << c.LT, 0); ttag[i].assign(1u << c.LT, 0); }
    ras.assign(1u << (c.LR < 0 ? 0 : c.LR), 0);
  }
  uint32_t btb_idx(uint32_t pc) const { return (pc >> 2) & ((1u << c.LB) - 1); }
  uint32_t btb_tag(uint32_t pc) const { return (pc >> (2 + c.LB)) & ((1u << c.TBB) - 1); }
  uint32_t full_target(uint32_t pc, uint32_t lo) const { uint32_t m = ((1u << c.TW) - 1) << 2; return (pc & ~m & ~3u) | (lo << 2); }
  uint32_t tgt_lo(uint32_t t) const { return (t >> 2) & ((1u << c.TW) - 1); }

  // ---------------- lookup (F1) ----------------
  void lookup(uint32_t pc, Meta &m) const {
    m.pc = pc; m.ghr = ghr; m.thr = thr;
    const BtbE &e = btb[btb_idx(pc)];
    m.btb_hit = !c.nobtb && e.v && e.tag == btb_tag(pc); m.btb_type = e.type; m.btb_target = full_target(pc, e.tgt);
    m.itc_hit = false;
    if (c.LI) {
      uint32_t p = pc >> 2;
      m.itc_idx = (p ^ fold(thr, c.HT, c.LI)) & ((1u << c.LI) - 1);
      m.itc_tag = ((p >> c.LI) ^ fold(thr, c.HT, c.TI)) & ((1u << c.TI) - 1);
      const ItcE &i = itc[m.itc_idx];
      m.itc_hit = i.v && i.tag == m.itc_tag; m.itc_target = c.tgtfix ? i.tgt << 2 : full_target(pc, i.tgt);
    }
    m.ras_top = c.LR < 0 ? 0 : ras[(rasp - 1) & (ras.size() - 1)] << 2;
    uint32_t p = pc >> 2;
    m.prov = m.alt = -1; m.weak = false;
    if (c.kind == K_NT) { m.dir = false; return; }
    if (c.kind == K_GSHARE) {
      m.bim_idx = (p ^ (uint32_t)(ghr & ((1ull << c.HG) - 1)) << (c.LBIM > c.HG ? c.LBIM - c.HG : 0)) & ((1u << c.LBIM) - 1);
      m.bim = bim[m.bim_idx]; m.dir = m.bim >= 2; return;
    }
    m.bim_idx = p & ((1u << c.LBIM) - 1); m.bim = bim[m.bim_idx];
    bool base = m.bim >= 2; m.dir = base;
    if (c.kind == K_BIMODAL) return;
    for (int i = 0; i < c.NT; i++) {
      int L = c.hist[i];
      m.idx[i] = (p ^ (p >> c.LT) ^ fold(ghr, L, c.LT)) & ((1u << c.LT) - 1);
      m.tag[i] = (p ^ fold(ghr, L, c.TT) ^ (fold(ghr, L, c.TT - 1) << 1)) & ((1u << c.TT) - 1);
      m.ctr[i] = tctr[i][m.idx[i]]; m.u[i] = tu[i][m.idx[i]];
      m.hit[i] = ttag[i][m.idx[i]] == m.tag[i];
      if (m.hit[i]) { m.alt = m.prov; m.prov = i; }
    }
    m.alt_pred = m.alt >= 0 ? m.ctr[m.alt] >= 4 : base;
    if (m.prov >= 0) {
      m.prov_pred = m.ctr[m.prov] >= 4;
      m.weak = (m.ctr[m.prov] == 3 || m.ctr[m.prov] == 4) && m.u[m.prov] == 0;
      m.dir = (m.weak && use_alt >= 8) ? m.alt_pred : m.prov_pred;
    }
  }

  // ---------------- table update (EX) ----------------
  static uint8_t sat(uint8_t v, bool up, int max) { return up ? (v < max ? v + 1 : v) : (v > 0 ? v - 1 : v); }
  void dir_update(const Meta &m, bool taken) {
    if (c.kind == K_NT) return;
    if (c.kind != K_TAGE) { bim[m.bim_idx] = sat(m.bim, taken, 3); return; }
    int umax = (1 << c.UB) - 1;
    if (m.prov >= 0) {
      int p = m.prov;
      if (m.weak && m.prov_pred != m.alt_pred) use_alt = sat(use_alt, m.alt_pred == taken, 15);
      tctr[p][m.idx[p]] = sat(m.ctr[p], taken, 7);
      if (m.prov_pred != m.alt_pred) tu[p][m.idx[p]] = sat(m.u[p], m.prov_pred == taken, umax);
      if (m.u[p] == 0 && m.alt < 0) bim[m.bim_idx] = sat(m.bim, taken, 3);
    } else bim[m.bim_idx] = sat(m.bim, taken, 3);
    bool longest_pred = m.prov >= 0 ? m.prov_pred : (m.bim >= 2);
    if (longest_pred != taken && m.prov < c.NT - 1) {
      int j = -1;
      for (int i = m.prov + 1; i < c.NT; i++) if (m.u[i] == 0) { j = i; break; }
      if (j >= 0) { ttag[j][m.idx[j]] = m.tag[j]; tctr[j][m.idx[j]] = taken ? 4 : 3; tu[j][m.idx[j]] = 0; }
      else for (int i = m.prov + 1; i < c.NT; i++) tu[i][m.idx[i]] = m.u[i] - 1;
    }
    rstcnt = (rstcnt + 1) & ((1u << c.LRST) - 1);
    if (rstcnt == 0) for (int i = 0; i < c.NT; i++) for (auto &x : tu[i]) x >>= 1;
  }
  // direct branch whose target cannot be expressed as {pc[31:TW+2], target[TW+1:2]}
  bool far(uint32_t pc, uint32_t tgt, int type) const {
    return c.tgtfix && (type == T_COND || type == T_JUMP || type == T_CALL) && ((pc ^ tgt) >> (c.TW + 2)) != 0;
  }
  void apply(const Pend &p) {
    const Meta &m = p.m;
    BtbE &e = btb[btb_idx(m.pc)];
    bool same = e.v && e.tag == btb_tag(m.pc);                   // entry still the looked-up one
    bool tagok = c.pinv == 2 || same;
    if (!p.isbr) { if (!c.pinv || (m.btb_hit && tagok)) e.v = false; return; }      // phantom: invalidate
    bool f1cond = m.btb_hit && m.btb_type == T_COND;
    if (p.type == T_COND && (f1cond || p.taken || m.dir)) dir_update(m, p.taken);
    if (p.taken && !far(m.pc, p.tgt, p.type)) e = BtbE{true, btb_tag(m.pc), p.type, tgt_lo(p.tgt)};
    else if (p.taken) { if (same) e.v = false; }                 // not representable: drop a stale entry
    else if (m.btb_hit && m.btb_type != p.type && (!c.pinv || tagok)) e.v = false;
    if (c.LI && (p.type == T_IND || p.type == T_ICALL)) {
      uint32_t pred = m.itc_hit ? m.itc_target : m.btb_target;
      if (!(m.btb_hit && pred == p.tgt)) itc[m.itc_idx] = ItcE{true, m.itc_tag, c.tgtfix ? p.tgt >> 2 : tgt_lo(p.tgt)};
    }
  }
  // IF1 fetch decision from a lookup (what the RTL drives on f_taken / f_target)
  void predict(const Meta &m, bool &f1_taken, uint32_t &f1_tgt) const {
    f1_taken = false; f1_tgt = 0;
    if (!m.btb_hit) return;
    switch (m.btb_type) {
    case T_COND: f1_taken = m.dir; f1_tgt = m.btb_target; break;
    case T_RET: f1_taken = true; f1_tgt = c.LR < 0 ? m.btb_target : m.ras_top; break;
    case T_IND: case T_ICALL: f1_taken = true; f1_tgt = m.itc_hit ? m.itc_target : m.btb_target; break;
    default: f1_taken = true; f1_tgt = m.btb_target;
    }
  }

  // ---------------- one control-flow instruction ----------------
  // returns pipeline penalty in cycles (0, 2 = decode redirect, 3 = execute redirect)
  int step(uint32_t pc, uint32_t tgt, int type, bool taken, Meta &m) {
    lookup(pc, m);
    bool hit = m.btb_hit && m.btb_type == type;
    uint32_t actual = taken ? tgt : pc + 4;
    int cost;
    bool f1_taken; uint32_t f1_tgt;
    predict(m, f1_taken, f1_tgt);
    m.f1_taken = f1_taken; m.f1_tgt = f1_tgt;
    if (hit) {
      uint32_t f1_next = f1_taken ? f1_tgt : pc + 4;
      if (f1_next == actual) cost = 0;
      else if (type == T_COND) cost = (f1_taken == taken) ? 2 : 3;
      else if (type == T_JUMP || type == T_CALL) cost = 2;
      else cost = 3;
    } else {
      switch (type) {
      case T_COND: cost = (m.dir != taken) ? 3 : (taken ? 2 : 0); break;
      case T_JUMP: case T_CALL: cost = 2; break;
      case T_RET: cost = (c.LR >= 0 && m.ras_top == tgt) ? 2 : 3; break;
      default: cost = 3;
      }
      if (f1_taken && cost < 2) cost = 2;
    }
    s.br[type]++;
    if (type == T_COND) { s.cond_taken += taken; s.dir_wrong += (m.dir != taken); if (hit && c.kind == K_TAGE && (m.bim >= 2) != m.dir && (m.dir || m.bim >= 2)) s.slow_diff++; }
    if (cost == 3) s.mis[type]++; else if (cost == 2) s.idr[type]++;
    if (taken) { s.taken_cf++; s.taken_hit0 += (cost == 0); }
    // speculative state (repaired immediately on a redirect => equals architectural sequence)
    if (type == T_COND && (c.allhist || (m.btb_hit && m.btb_type == T_COND) || taken)) ghr = (ghr << 1) | (taken ? 1 : 0);
    if (c.LR >= 0) {
      if (type == T_CALL || type == T_ICALL) { ras[rasp & (ras.size() - 1)] = (pc + 4) >> 2; rasp = (rasp + 1) & (ras.size() - 1); }
      else if (type == T_RET) rasp = (rasp - 1) & (ras.size() - 1);
    }
    if (type == T_IND || type == T_ICALL) thr = ((thr << 2) ^ (tgt >> 2)) & ((1u << c.HT) - 1);
    q.push_back(Pend{m, (uint8_t)type, taken, tgt, true});
    while ((int)q.size() > c.delay) { apply(q.front()); q.pop_front(); }
    return cost;
  }
  // non-branch PC: returns penalty (2 if a stale/aliased BTB entry redirected fetch;
  // with phrep also when it only polluted the speculative history and ID must repair it)
  int step_nonbranch(uint32_t pc) {
    const BtbE &e = btb[btb_idx(pc)];
    if (c.nobtb || !e.v || e.tag != btb_tag(pc)) return 0;
    Meta m; lookup(pc, m);
    bool tk = m.btb_type == T_COND ? m.dir : true;
    s.phantom++;
    q.push_back(Pend{m, 0, false, 0, false});
    while ((int)q.size() > c.delay) { apply(q.front()); q.pop_front(); }
    return (tk || c.phrep) ? 2 : 0;
  }
};

// Address remapping used by the stress runs (bpsim remap=1, cosim -r 1). The suite's code is
// < 32 KiB at address 0, so it never aliases in the BTB (15 PC bits) and never leaves the first
// 1 MiB region. The remap splits the address into 512-byte blocks b = a >> 9 and places block b at
// bits [11:9] = b & 7, bits [26:17] = b >> 3, plus 0x0800_0000 for every second group of 8 blocks.
// Blocks 8 apart then alias in the BTB and branches between groups cross a 1 MiB region. Only the
// address stream changes; RTL and model see the same one (it is not a valid program layout).
static inline uint32_t remap_addr(uint32_t a) {
  uint32_t b = a >> 9;
  return (a & 0x1FFu) | ((b & 7u) << 9) | ((b >> 3) << 17) | (((b >> 3) & 1u) ? 0x08000000u : 0u);
}
