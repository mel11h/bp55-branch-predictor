// =============================================================================
// BP55 v2 - branch prediction unit for a 6-stage in-order RV32IM core
// Target: ICsprout 55 nm open PDK (ics55_LLSC_H7C standard cells, no SRAM macro
// available => every table is a flip-flop array and the budget is ~8 Kbit).
//
//   BTB   : 128 x {v, tag[7:0], type[2:0], target[19:2]}   direct mapped
//   BIM   : 512 x 2-bit bimodal counters (TAGE base), stored as 64 rows x 8 counters
//   TAGE  : 3 x 64 x {tag[6:0], ctr[2:0], u}   histories 5 / 12 / 28
//   ITC   : 32 x {v, tag[7:0], target[31:2]}   indirect target cache, 6-bit target history
//   RAS   : 8 x 30-bit return address stack
//   CLR   : 7-bit post-reset clear sequencer (busy + 6-bit row counter)
//
// The behaviour is bit-identical to sim/bp_model.h with the v2 switches
// (pinv=1 tgtfix=1); verified by sim/cosim.sh. v1 is rtl/bp55.sv at git HEAD.
//
// ------------------------------- TIMING CONTRACT ----------------------------
// All inputs are sampled at the rising edge of clk; rst_n is an asynchronous
// active-low reset. "Cycle N" below means the clock period ending at edge N.
//
// Post-reset clear (f_busy)
//   After rst_n is released f_busy stays high for 2^LC = 64 cycles while the
//   sequencer zeroes the bimodal (8 counters per cycle), TAGE (one row of each
//   table per cycle, all u bits at once) and RAS rows. While f_busy = 1:
//   f_hit = f_taken = f_dir = 0, f_type = 0, f_ras_top = 0 (fall-through, no
//   state change), f_meta / f_ckpt are 2-state defined, and u_fire / r_fire /
//   f_fire are ignored (training is dropped, which is safe: tables are being
//   zeroed; the speculative registers are still at their reset values).
//
// f_* lookup (IF1)
//   f_hit .. f_ckpt are purely combinational from f_pc and the current state.
//   They may change while an instruction is held in IF1 (training and
//   redirects can update tables); the values that count are those sampled in
//   the cycle in which f_fire = 1. The core captures f_meta and f_ckpt into its
//   IF1->IF2 pipeline register at that same edge.
//   f_fire = 1 means "the instruction at f_pc leaves IF1 at this edge"
//   (valid & ~stall & ~kill). The speculative GHR / THR / RAS update for that
//   lookup happens at exactly that edge, once. A held (stalled) lookup must
//   drive f_fire = 0; it then has no effect on state.
//   f_fire must be 0 in a cycle with r_fire = 1 (KNOWN OPEN: the predictor
//   does not support a lookup in the redirect cycle; the redirect wins and the
//   lookup's speculative update is dropped).
//
// r_* redirect / repair (ID or EX)
//   r_fire = 1 for exactly one cycle per redirect. At that edge GHR, THR, RAS
//   pointer and the RAS top entry are restored from r_ckpt (the f_ckpt
//   captured with the redirecting instruction), then the architecturally
//   correct operation (r_ghr_shift/r_taken, r_push/r_push_addr, r_pop,
//   r_thr_shift/r_target) is applied. With all four operation bits 0 this is
//   a plain flush that restores the checkpoint (trap / interrupt / any
//   re-fetch from the instruction that owns r_ckpt). The repair restores the
//   RAS top entry only, so it is exact for at most two younger wrong-path
//   lookups (KNOWN OPEN for deeper fetch queues). A redirect is idempotent,
//   but the contract is still one pulse per redirect.
//
// u_* training (EX)
//   u_fire = 1 for exactly one cycle per retiring/resolving instruction; every
//   cycle with u_fire = 1 is one training message. A stalled EX/MEM stage must
//   deassert u_fire (u_fire = valid & ~stall): the use_alt counter and the
//   u-bit reset counter are not idempotent, so a message held for two cycles
//   would be counted twice. u_meta is the f_meta captured with the
//   instruction. u_isbr = 0 reports a non-control-flow instruction whose lookup
//   hit the BTB (phantom); the entry is invalidated only if that lookup hit
//   (u_meta.b_hit) and the entry still carries the same tag. Sending u_isbr = 0
//   for an instruction whose lookup missed is allowed and has no effect.
// =============================================================================
// bp_fold lives in this file so the predictor stays a single-file IP.
/* verilator lint_off DECLFILENAME */
module bp_fold #(parameter int HW = 28, parameter int L = 12, parameter int W = 6) (
  input  logic [HW-1:0] h,
  output logic [W-1:0]  o
);
  always_comb begin
    o = '0;
    for (int k = 0; k < L; k++) o[k % W] = o[k % W] ^ h[k];
  end
endmodule
/* verilator lint_on DECLFILENAME */

module bp55 #(
  parameter int LB   = 7,   // log2 BTB entries
  parameter int LBIM = 9,   // log2 bimodal entries (>= 4)
  parameter int LT   = 6,   // log2 entries per TAGE table
  parameter int LI   = 5,   // log2 ITC entries
  parameter int LR   = 3    // log2 RAS depth
) (
  input  logic         clk,
  input  logic         rst_n,
  // ---- IF1 lookup (combinational from f_pc; state advances on f_fire) ---------
  // f_pc[1:0] is ignored (RV32 without C).
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]  f_pc,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic         f_fire,     // the lookup at f_pc is accepted by the fetch stage at this edge
  output logic         f_busy,     // post-reset clear in progress: predictions forced to fall-through
  output logic         f_hit,      // BTB hit: this PC is a known control-flow instruction
  output logic [2:0]   f_type,     // BTB type (0 when f_hit = 0)
  output logic         f_taken,    // redirect fetch to f_target
  output logic [31:0]  f_target,   // meaningful when f_taken = 1
  output logic         f_dir,      // TAGE direction (valid for any PC; used by ID on a BTB miss)
  output logic [31:0]  f_ras_top,  // RAS top (used by ID for returns that missed the BTB)
  output logic [103:0] f_meta,     // capture when f_fire = 1; carried to EX for training
  output logic [66:0]  f_ckpt,     // capture when f_fire = 1; carried to ID/EX for repair
  // ---- redirect / repair (one pulse per redirect) -------------------------------
  input  logic         r_fire,
  input  logic [66:0]  r_ckpt,
  input  logic         r_ghr_shift, r_taken,
  input  logic         r_push, r_pop,
  // r_push_addr[1:0] and r_target[31:HT+2], r_target[1:0] are not used.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]  r_push_addr,
  input  logic         r_thr_shift,
  input  logic [31:0]  r_target,
  /* verilator lint_on UNUSEDSIGNAL */
  // ---- training (one pulse per instruction) -------------------------------------
  input  logic         u_fire,
  input  logic         u_isbr,     // 0: the BTB hit on a non-control-flow instruction -> invalidate
  // u_pc[1:0], the u_pc bits above the BTB tag and u_target[1:0] are not used.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]  u_pc,
  input  logic [2:0]   u_type,
  input  logic         u_taken,
  input  logic [31:0]  u_target,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [103:0] u_meta
);
  localparam int TBB = 8, TW = 18, TT = 7, TI = 8, HL = 28, HT = 6, NT = 3;
  localparam int NB = 1 << LB, NI = 1 << LI, NR = 1 << LR, NTE = 1 << LT;
  localparam int BL = 8, NBR = (1 << LBIM) / BL;          // bimodal: 8 counters per row
  // clear sequencer: enough rows for the largest table (TAGE rows, bimodal rows, RAS)
  localparam int LC0 = (LT > LBIM - 3) ? LT : LBIM - 3;
  localparam int LC  = (LC0 > LR) ? LC0 : LR;
  localparam logic [2:0] T_COND = 3'd0, T_JUMP = 3'd1, T_CALL = 3'd2, T_RET = 3'd3, T_IND = 3'd4, T_ICALL = 3'd5;

  // ------------------------------- state -------------------------------------
  logic [NB-1:0]     btb_v;
  logic [TBB-1:0]    btb_tag  [NB];
  logic [2:0]        btb_type [NB];
  logic [TW-1:0]     btb_tgt  [NB];
  logic [NI-1:0]     itc_v;
  logic [TI-1:0]     itc_tag  [NI];
  logic [29:0]       itc_tgt  [NI];       // full target: an indirect target can be anywhere
  logic [2*BL-1:0]   bim      [NBR];
  logic [TT-1:0]     ttag0 [NTE], ttag1 [NTE], ttag2 [NTE];
  logic [2:0]        tctr0 [NTE], tctr1 [NTE], tctr2 [NTE];
  logic [NTE-1:0]    tu0, tu1, tu2;
  logic [29:0]       ras [NR];
  logic [LR-1:0]     rasp;
  logic [HL-1:0]     ghr;
  logic [HT-1:0]     thr;
  logic [3:0]        use_alt;
  logic [10:0]       rstcnt;
  logic              clr_busy;
  logic [LC-1:0]     clr_cnt;

  // --------------------------- post-reset clear ------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin clr_busy <= 1'b1; clr_cnt <= '0; end
    else if (clr_busy) begin
      clr_cnt  <= clr_cnt + 1'b1;
      clr_busy <= ~&clr_cnt;
    end
  end
  wire busy = clr_busy;
  wire uf   = u_fire && !busy;
  wire rf   = r_fire && !busy;

  // ------------------------------- lookup ------------------------------------
  wire [29:0] p = f_pc[31:2];
  // BTB (type / target gated by the hit so they are defined while the entry is invalid)
  wire [LB-1:0]  b_idx = p[LB-1:0];
  wire           b_hit = !busy && btb_v[b_idx] && (btb_tag[b_idx] == p[LB +: TBB]);
  wire [2:0]     b_type = b_hit ? btb_type[b_idx] : 3'd0;
  wire [TW-1:0]  b_tgt  = b_hit ? btb_tgt[b_idx] : '0;
  // ITC
  wire [LI-1:0]  thr_f5;
  bp_fold #(.HW(HT), .L(HT), .W(LI)) u_fthr (.h(thr), .o(thr_f5));
  wire [LI-1:0]  i_idx = p[LI-1:0] ^ thr_f5;
  wire [TI-1:0]  i_tag = p[LI +: TI] ^ {{(TI-HT){1'b0}}, thr};
  wire           i_hit = itc_v[i_idx] && (itc_tag[i_idx] == i_tag);
  wire [29:0]    i_tgt = itc_tgt[i_idx];
  // RAS
  wire [LR-1:0]  rasp_m1 = rasp - 1'b1;
  wire [29:0]    ras_top = busy ? 30'd0 : ras[rasp_m1];
  // bimodal
  wire [2*BL-1:0] bim_row = bim[p[3 +: LBIM-3]];
  wire [1:0]     bim_rd = busy ? 2'b00 : bim_row[{p[2:0], 1'b0} +: 2];
  // TAGE: folded histories (pure XOR trees of the GHR, off the PC-critical path)
  logic [NT-1:0][LT-1:0] fi;
  logic [NT-1:0][TT-1:0] ft;
  bp_fold #(.HW(HL), .L(5),  .W(LT)) u_fi0 (.h(ghr), .o(fi[0]));
  bp_fold #(.HW(HL), .L(12), .W(LT)) u_fi1 (.h(ghr), .o(fi[1]));
  bp_fold #(.HW(HL), .L(28), .W(LT)) u_fi2 (.h(ghr), .o(fi[2]));
  bp_fold #(.HW(HL), .L(5),  .W(TT)) u_ft0 (.h(ghr), .o(ft[0]));
  bp_fold #(.HW(HL), .L(12), .W(TT)) u_ft1 (.h(ghr), .o(ft[1]));
  bp_fold #(.HW(HL), .L(28), .W(TT)) u_ft2 (.h(ghr), .o(ft[2]));
  // per-table index / tag / read (continuous assignments: portable to Icarus 12)
  wire [LT-1:0] t_idx0 = p[LT-1:0] ^ p[LT +: LT] ^ fi[0];
  wire [LT-1:0] t_idx1 = p[LT-1:0] ^ p[LT +: LT] ^ fi[1];
  wire [LT-1:0] t_idx2 = p[LT-1:0] ^ p[LT +: LT] ^ fi[2];
  wire [TT-1:0] t_tag0 = p[TT-1:0] ^ ft[0] ^ {fi[0], 1'b0};
  wire [TT-1:0] t_tag1 = p[TT-1:0] ^ ft[1] ^ {fi[1], 1'b0};
  wire [TT-1:0] t_tag2 = p[TT-1:0] ^ ft[2] ^ {fi[2], 1'b0};
  wire          t_u0   = !busy && tu0[t_idx0];
  wire          t_u1   = !busy && tu1[t_idx1];
  wire          t_u2   = !busy && tu2[t_idx2];
  wire [2:0]    t_ctr0 = busy ? 3'd0 : tctr0[t_idx0];
  wire [2:0]    t_ctr1 = busy ? 3'd0 : tctr1[t_idx1];
  wire [2:0]    t_ctr2 = busy ? 3'd0 : tctr2[t_idx2];
  wire          t_hit0 = !busy && (ttag0[t_idx0] == t_tag0);
  wire          t_hit1 = !busy && (ttag1[t_idx1] == t_tag1);
  wire          t_hit2 = !busy && (ttag2[t_idx2] == t_tag2);
  // provider / alternate selection
  wire       l_base      = bim_rd[1];
  wire       l_has       = t_hit0 | t_hit1 | t_hit2;
  wire [2:0] l_pctr      = t_hit2 ? t_ctr2 : t_hit1 ? t_ctr1 : t_ctr0;
  wire       l_pu        = t_hit2 ? t_u2 : t_hit1 ? t_u1 : t_u0;
  wire       l_alt_pred  = t_hit2 ? (t_hit1 ? t_ctr1[2] : t_hit0 ? t_ctr0[2] : l_base)
                         : (t_hit1 && t_hit0) ? t_ctr0[2] : l_base;
  wire       l_prov_pred = l_pctr[2];
  wire       l_weak      = (l_pctr == 3'd3 || l_pctr == 3'd4) && !l_pu;
  wire       l_dir       = !l_has ? l_base : (l_weak && use_alt[3]) ? l_alt_pred : l_prov_pred;
  // final IF1 prediction
  wire        is_ind = (b_type == T_IND) || (b_type == T_ICALL);
  wire [29:0] ind    = i_hit ? i_tgt : {p[29:TW], b_tgt};       // indirect: ITC (full) else BTB
  assign f_busy    = busy;
  assign f_hit     = b_hit;
  assign f_type    = b_type;
  assign f_dir     = l_dir;
  assign f_taken   = b_hit && (b_type == T_COND ? l_dir : 1'b1);
  assign f_ras_top = {ras_top, 2'b00};
  assign f_target  = (b_type == T_RET) ? {ras_top, 2'b00} : is_ind ? {ind, 2'b00} : {p[29:TW], b_tgt, 2'b00};
  assign f_meta    = {l_dir, t_hit2, t_hit1, t_hit0, t_u2, t_u1, t_u0, t_ctr2, t_ctr1, t_ctr0,
                      t_tag2, t_tag1, t_tag0, t_idx2, t_idx1, t_idx0, bim_rd, i_tag, i_idx, ind, b_type, b_hit};
  assign f_ckpt    = {ras_top, rasp, thr, ghr};

  // -------------------------- speculative state ------------------------------
  wire [HL-1:0]  c_ghr;  wire [HT-1:0] c_thr;  wire [LR-1:0] c_rasp;  wire [29:0] c_top;
  assign {c_top, c_rasp, c_thr, c_ghr} = r_ckpt;
  wire [LR-1:0]  c_rasp_m1 = c_rasp - 1'b1;
  wire sp_cond = f_fire && b_hit && b_type == T_COND;
  wire sp_push = f_fire && b_hit && (b_type == T_CALL || b_type == T_ICALL);
  wire sp_pop  = f_fire && b_hit && b_type == T_RET;
  wire sp_ind  = f_fire && b_hit && is_ind;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ghr <= '0; thr <= '0; rasp <= '0; end
    else if (rf) begin
      ghr  <= r_ghr_shift ? {c_ghr[HL-2:0], r_taken} : c_ghr;
      thr  <= r_thr_shift ? ({c_thr[HT-3:0], 2'b00} ^ r_target[2 +: HT]) : c_thr;
      rasp <= r_push ? c_rasp + 1'b1 : r_pop ? c_rasp_m1 : c_rasp;
    end else begin
      if (sp_cond) ghr <= {ghr[HL-2:0], l_dir};
      if (sp_ind)  thr <= {thr[HT-3:0], 2'b00} ^ f_target[2 +: HT];
      if (sp_push) rasp <= rasp + 1'b1; else if (sp_pop) rasp <= rasp_m1;
    end
  end
  // RAS write port A: clear row / restore the top entry on a redirect (undoes a wrong-path
  // overwrite) / speculative push. Port B: the push of a redirect (c_rasp != c_rasp_m1).
  wire          rwa_en   = busy | rf | sp_push;
  wire [LR-1:0] rwa_addr = busy ? clr_cnt[LR-1:0] : rf ? c_rasp_m1 : rasp;
  wire [29:0]   rwa_data = busy ? 30'd0 : rf ? c_top : p + 30'd1;
  always_ff @(posedge clk) begin
    if (rwa_en) ras[rwa_addr] <= rwa_data;
    if (rf && r_push) ras[c_rasp] <= r_push_addr[31:2];
  end

  // ------------------------------ training -----------------------------------
  wire        m_bhit;  wire [2:0] m_btype;  wire [29:0] m_ind;  wire [LI-1:0] m_iidx;  wire [TI-1:0] m_itag;
  wire [1:0]  m_bim;   wire m_dir;
  wire [LT-1:0] m_idx0, m_idx1, m_idx2;  wire [TT-1:0] m_tag0, m_tag1, m_tag2;
  wire [2:0]  m_ctr0, m_ctr1, m_ctr2;    wire m_u0, m_u1, m_u2, m_h0, m_h1, m_h2;
  assign {m_dir, m_h2, m_h1, m_h0, m_u2, m_u1, m_u0, m_ctr2, m_ctr1, m_ctr0,
          m_tag2, m_tag1, m_tag0, m_idx2, m_idx1, m_idx0, m_bim, m_itag, m_iidx, m_ind, m_btype, m_bhit} = u_meta;

  function automatic logic [2:0] sat3(input logic [2:0] v, input logic up);
    sat3 = up ? (v == 3'd7 ? v : v + 3'd1) : (v == 3'd0 ? v : v - 3'd1);
  endfunction
  function automatic logic [1:0] sat2(input logic [1:0] v, input logic up);
    sat2 = up ? (v == 2'd3 ? v : v + 2'd1) : (v == 2'd0 ? v : v - 2'd1);
  endfunction

  wire u_br    = uf && u_isbr;
  wire u_cond  = u_br && u_type == T_COND && ((m_bhit && m_btype == T_COND) || u_taken || m_dir);
  wire u_has   = m_h0 | m_h1 | m_h2;
  wire [1:0] u_prov = m_h2 ? 2'd2 : m_h1 ? 2'd1 : 2'd0;
  wire [2:0] u_pctr = m_h2 ? m_ctr2 : m_h1 ? m_ctr1 : m_ctr0;
  wire       u_pu   = m_h2 ? m_u2 : m_h1 ? m_u1 : m_u0;
  wire       u_noalt = m_h2 ? !(m_h1 | m_h0) : m_h1 ? !m_h0 : 1'b1;
  wire       u_altp = m_h2 ? (m_h1 ? m_ctr1[2] : m_h0 ? m_ctr0[2] : m_bim[1]) : (m_h1 && m_h0) ? m_ctr0[2] : m_bim[1];
  wire       u_provp = u_pctr[2];
  wire       u_weak = (u_pctr == 3'd3 || u_pctr == 3'd4) && !u_pu;
  wire       u_longp = u_has ? u_provp : m_bim[1];
  wire       u_misl  = u_cond && (u_longp != u_taken);
  // allocation: first table above the provider with u == 0, otherwise age them
  wire [2:0] above = {!m_h2, !m_h2 && !m_h1, !u_has};                              // tables above provider
  wire [2:0] cand = above & ~{m_u2, m_u1, m_u0};                                   // ... whose entry is not useful
  wire [2:0] alloc = !u_misl ? 3'b000 : cand[0] ? 3'b001 : cand[1] ? 3'b010 : cand[2] ? 3'b100 : 3'b000;
  wire [2:0] decay = (u_misl && cand == 3'b000) ? above : 3'b000;
  wire [2:0] isprov = (u_cond && u_has) ? (3'b001 << u_prov) : 3'b000;
  wire       u_wrap = u_cond && (rstcnt == 11'h7ff);
  wire [2:0] ctr_new = sat3(u_pctr, u_taken);
  wire [2:0] ctr_alloc = u_taken ? 3'd4 : 3'd3;
  wire       u_tflip = u_provp != u_altp;
  wire       u_tval  = u_provp == u_taken;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin use_alt <= 4'd8; rstcnt <= '0; end
    else if (u_cond) begin
      rstcnt <= rstcnt + 1'b1;
      if (u_has && u_weak && u_tflip)
        use_alt <= (u_altp == u_taken) ? (use_alt == 4'd15 ? use_alt : use_alt + 1'b1) : (use_alt == 4'd0 ? use_alt : use_alt - 1'b1);
    end
  end
  // TAGE tables (no reset on payload bits: keeps them on the small non-reset flop).
  // One write port per table; during the clear it writes row clr_cnt with zero.
  wire [LT-1:0] tw_idx0 = busy ? clr_cnt[LT-1:0] : m_idx0;
  wire [LT-1:0] tw_idx1 = busy ? clr_cnt[LT-1:0] : m_idx1;
  wire [LT-1:0] tw_idx2 = busy ? clr_cnt[LT-1:0] : m_idx2;
  always_ff @(posedge clk) begin
    if (busy | isprov[0] | alloc[0]) tctr0[tw_idx0] <= busy ? 3'd0 : alloc[0] ? ctr_alloc : ctr_new;
    if (busy | isprov[1] | alloc[1]) tctr1[tw_idx1] <= busy ? 3'd0 : alloc[1] ? ctr_alloc : ctr_new;
    if (busy | isprov[2] | alloc[2]) tctr2[tw_idx2] <= busy ? 3'd0 : alloc[2] ? ctr_alloc : ctr_new;
    if (busy | alloc[0]) ttag0[tw_idx0] <= busy ? '0 : m_tag0;
    if (busy | alloc[1]) ttag1[tw_idx1] <= busy ? '0 : m_tag1;
    if (busy | alloc[2]) ttag2[tw_idx2] <= busy ? '0 : m_tag2;
  end
  // useful bits: the periodic graceful reset also clears them during the post-reset clear
  always_ff @(posedge clk) begin
    if (u_wrap | busy) tu0 <= '0;
    else if (alloc[0] | decay[0]) tu0[m_idx0] <= 1'b0;
    else if (isprov[0] && u_tflip) tu0[m_idx0] <= u_tval;
    if (u_wrap | busy) tu1 <= '0;
    else if (alloc[1] | decay[1]) tu1[m_idx1] <= 1'b0;
    else if (isprov[1] && u_tflip) tu1[m_idx1] <= u_tval;
    if (u_wrap | busy) tu2 <= '0;
    else if (alloc[2] | decay[2]) tu2[m_idx2] <= 1'b0;
    else if (isprov[2] && u_tflip) tu2[m_idx2] <= u_tval;
  end
  // bimodal: one row write port with per-counter enables; the clear writes a whole row
  wire          bim_upd  = u_cond && (!u_has || (!u_pu && u_noalt));
  wire [BL-1:0] bim_lane = busy ? {BL{1'b1}} : bim_upd ? (BL'(1) << u_pc[4:2]) : {BL{1'b0}};
  wire [LBIM-4:0] bw_row = busy ? clr_cnt[LBIM-4:0] : u_pc[5 +: LBIM-3];
  wire [1:0]    bim_wd   = busy ? 2'b00 : sat2(m_bim, u_taken);
  always_ff @(posedge clk) begin
    for (int k = 0; k < BL; k++)
      if (bim_lane[k]) bim[bw_row][2*k +: 2] <= bim_wd;
  end
  // BTB
  wire [LB-1:0] ub_idx  = u_pc[2 +: LB];
  wire          ub_tagok = btb_v[ub_idx] && (btb_tag[ub_idx] == u_pc[2 + LB +: TBB]);  // entry still the looked-up one
  wire          ub_direct = u_type == T_COND || u_type == T_JUMP || u_type == T_CALL;
  wire          ub_far  = ub_direct && (u_pc[31:TW+2] != u_target[31:TW+2]);     // direct target not representable
  wire          ub_wr   = u_br && u_taken && !ub_far;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) btb_v <= '0;
    else if (uf) begin
      if (!u_isbr) begin
        if (m_bhit && ub_tagok) btb_v[ub_idx] <= 1'b0;                // phantom: drop the aliased entry
      end else if (u_taken) begin
        if (!ub_far) btb_v[ub_idx] <= 1'b1;
        else if (ub_tagok) btb_v[ub_idx] <= 1'b0;                     // stale entry of a now-far branch
      end else if (m_bhit && m_btype != u_type && ub_tagok) btb_v[ub_idx] <= 1'b0;
    end
  end
  always_ff @(posedge clk) if (ub_wr) begin
    btb_tag[ub_idx]  <= u_pc[2 + LB +: TBB];
    btb_type[ub_idx] <= u_type;
    btb_tgt[ub_idx]  <= u_target[2 +: TW];
  end
  // ITC (full-width target: rewritten only when the prediction was wrong)
  wire u_ind    = u_br && (u_type == T_IND || u_type == T_ICALL);
  wire u_ind_ok = m_bhit && (m_ind == u_target[31:2]);
  wire ui_wr    = u_ind && !u_ind_ok;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) itc_v <= '0;
    else if (ui_wr) itc_v[m_iidx] <= 1'b1;
  end
  always_ff @(posedge clk) if (ui_wr) begin
    itc_tag[m_iidx] <= m_itag;
    itc_tgt[m_iidx] <= u_target[31:2];
  end
endmodule
