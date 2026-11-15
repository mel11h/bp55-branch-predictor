// =============================================================================
// BP55 - branch prediction unit for a 6-stage in-order RV32IM core
// Target: ICsprout 55 nm open PDK (ics55_LLSC_H7C standard cells, no SRAM macro
// available => every table is a flip-flop array and the budget is ~8 Kbit).
//
//   BTB   : 128 x {v, tag[7:0], type[2:0], target[19:2]}   direct mapped
//   BIM   : 512 x 2-bit bimodal counters (TAGE base)
//   TAGE  : 3 x 64 x {tag[6:0], ctr[2:0], u}   histories 5 / 12 / 28
//   ITC   : 32 x {v, tag[7:0], target[19:2]}   indirect target cache, 6-bit target history
//   RAS   : 8 x 30-bit return address stack
//
// Interfaces
//   f_* : lookup in IF1, fully combinational from f_pc (single-cycle, zero-bubble).
//         Speculative GHR / THR / RAS update on f_valid.
//   r_* : redirect from ID or EX. Restores the checkpoint taken at lookup time and
//         applies the architecturally correct history / RAS operation.
//   u_* : table training at EX using the metadata captured at lookup time.
// The behaviour is bit-identical to sim/bp_model.h (verified by co-simulation).
// =============================================================================
module bp_fold #(parameter int HW = 28, parameter int L = 12, parameter int W = 6) (
  input  logic [HW-1:0] h,
  output logic [W-1:0]  o
);
  always_comb begin
    o = '0;
    for (int k = 0; k < L; k++) o[k % W] = o[k % W] ^ h[k];
  end
endmodule

module bp55 #(
  parameter int LB   = 7,   // log2 BTB entries
  parameter int LBIM = 9,   // log2 bimodal entries
  parameter int LT   = 6,   // log2 entries per TAGE table
  parameter int LI   = 5,   // log2 ITC entries
  parameter int LR   = 3    // log2 RAS depth
) (
  input  logic        clk,
  input  logic        rst_n,
  // ---- IF1 lookup -----------------------------------------------------------
  input  logic        f_valid,
  input  logic [31:0] f_pc,
  output logic        f_hit,      // BTB hit: this PC is a known control-flow instruction
  output logic [2:0]  f_type,
  output logic        f_taken,    // redirect fetch to f_target
  output logic [31:0] f_target,
  output logic        f_dir,      // TAGE direction (valid for any PC; used by ID on a BTB miss)
  output logic [31:0] f_ras_top,  // RAS top (used by ID for returns that missed the BTB)
  output logic [91:0] f_meta,     // carried to EX for training
  output logic [66:0] f_ckpt,     // carried to ID/EX for repair
  // ---- redirect / repair ----------------------------------------------------
  input  logic        r_valid,
  input  logic [66:0] r_ckpt,
  input  logic        r_ghr_shift, r_taken,
  input  logic        r_push, r_pop,
  input  logic [31:0] r_push_addr,
  input  logic        r_thr_shift,
  input  logic [31:0] r_target,
  // ---- training -------------------------------------------------------------
  input  logic        u_valid,
  input  logic        u_isbr,     // 0: the BTB hit on a non-control-flow instruction -> invalidate
  input  logic [31:0] u_pc,
  input  logic [2:0]  u_type,
  input  logic        u_taken,
  input  logic [31:0] u_target,
  input  logic [91:0] u_meta
);
  localparam int TBB = 8, TW = 18, TT = 7, TI = 8, HL = 28, HT = 6, NT = 3;
  localparam int NB = 1 << LB, NBIM = 1 << LBIM, NTE = 1 << LT, NI = 1 << LI, NR = 1 << LR;
  localparam logic [2:0] T_COND = 3'd0, T_JUMP = 3'd1, T_CALL = 3'd2, T_RET = 3'd3, T_IND = 3'd4, T_ICALL = 3'd5;

  // ------------------------------- state -------------------------------------
  logic [NB-1:0]     btb_v;
  logic [TBB-1:0]    btb_tag  [NB];
  logic [2:0]        btb_type [NB];
  logic [TW-1:0]     btb_tgt  [NB];
  logic [NI-1:0]     itc_v;
  logic [TI-1:0]     itc_tag  [NI];
  logic [TW-1:0]     itc_tgt  [NI];
  logic [1:0]        bim      [NBIM];
  logic [TT-1:0]     ttag0 [NTE], ttag1 [NTE], ttag2 [NTE];
  logic [2:0]        tctr0 [NTE], tctr1 [NTE], tctr2 [NTE];
  logic [NT-1:0][NTE-1:0] tu;
  logic [29:0]       ras [NR];
  logic [LR-1:0]     rasp;
  logic [HL-1:0]     ghr;
  logic [HT-1:0]     thr;
  logic [3:0]        use_alt;
  logic [10:0]       rstcnt;

  // ------------------------------- lookup ------------------------------------
  wire [29:0] p = f_pc[31:2];
  // BTB
  wire [LB-1:0]  b_idx = p[LB-1:0];
  wire           b_hit = btb_v[b_idx] && (btb_tag[b_idx] == p[LB +: TBB]);
  wire [2:0]     b_type = btb_type[b_idx];
  wire [TW-1:0]  b_tgt = btb_tgt[b_idx];
  // ITC
  wire [LI-1:0]  thr_f5;
  bp_fold #(.HW(HT), .L(HT), .W(LI)) u_fthr (.h(thr), .o(thr_f5));
  wire [LI-1:0]  i_idx = p[LI-1:0] ^ thr_f5;
  wire [TI-1:0]  i_tag = p[LI +: TI] ^ {{(TI-HT){1'b0}}, thr};
  wire           i_hit = itc_v[i_idx] && (itc_tag[i_idx] == i_tag);
  wire [TW-1:0]  i_tgt = itc_tgt[i_idx];
  // RAS
  wire [LR-1:0]  rasp_m1 = rasp - 1'b1;
  wire [29:0]    ras_top = ras[rasp_m1];
  // bimodal
  wire [1:0]     bim_rd = bim[p[LBIM-1:0]];
  // TAGE: folded histories (pure XOR trees of the GHR, off the PC-critical path)
  logic [NT-1:0][LT-1:0] fi;
  logic [NT-1:0][TT-1:0] ft;
  bp_fold #(.HW(HL), .L(5),  .W(LT)) u_fi0 (.h(ghr), .o(fi[0]));
  bp_fold #(.HW(HL), .L(12), .W(LT)) u_fi1 (.h(ghr), .o(fi[1]));
  bp_fold #(.HW(HL), .L(28), .W(LT)) u_fi2 (.h(ghr), .o(fi[2]));
  bp_fold #(.HW(HL), .L(5),  .W(TT)) u_ft0 (.h(ghr), .o(ft[0]));
  bp_fold #(.HW(HL), .L(12), .W(TT)) u_ft1 (.h(ghr), .o(ft[1]));
  bp_fold #(.HW(HL), .L(28), .W(TT)) u_ft2 (.h(ghr), .o(ft[2]));
  logic [NT-1:0][LT-1:0] t_idx;
  logic [NT-1:0][TT-1:0] t_tag;
  logic [NT-1:0][2:0]    t_ctr;
  logic [NT-1:0]         t_u, t_hit;
  always_comb begin
    for (int i = 0; i < NT; i++) begin
      t_idx[i] = p[LT-1:0] ^ p[LT +: LT] ^ fi[i];
      t_tag[i] = p[TT-1:0] ^ ft[i] ^ {fi[i], 1'b0};
      t_u[i]   = tu[i][t_idx[i]];
    end
    t_ctr[0] = tctr0[t_idx[0]]; t_hit[0] = ttag0[t_idx[0]] == t_tag[0];
    t_ctr[1] = tctr1[t_idx[1]]; t_hit[1] = ttag1[t_idx[1]] == t_tag[1];
    t_ctr[2] = tctr2[t_idx[2]]; t_hit[2] = ttag2[t_idx[2]] == t_tag[2];
  end
  // provider / alternate selection
  logic l_has, l_prov_pred, l_alt_pred, l_weak, l_dir;
  logic [2:0] l_pctr; logic l_pu;
  always_comb begin
    logic base;
    base = bim_rd[1];
    l_has = t_hit[0] | t_hit[1] | t_hit[2];
    if (t_hit[2])      begin l_pctr = t_ctr[2]; l_pu = t_u[2]; l_alt_pred = t_hit[1] ? t_ctr[1][2] : t_hit[0] ? t_ctr[0][2] : base; end
    else if (t_hit[1]) begin l_pctr = t_ctr[1]; l_pu = t_u[1]; l_alt_pred = t_hit[0] ? t_ctr[0][2] : base; end
    else               begin l_pctr = t_ctr[0]; l_pu = t_u[0]; l_alt_pred = base; end
    l_prov_pred = l_pctr[2];
    l_weak = (l_pctr == 3'd3 || l_pctr == 3'd4) && !l_pu;
    l_dir = !l_has ? base : (l_weak && use_alt[3]) ? l_alt_pred : l_prov_pred;
  end
  // final IF1 prediction
  wire [TW-1:0] ind_lo = i_hit ? i_tgt : b_tgt;
  wire is_ind = (b_type == T_IND) || (b_type == T_ICALL);
  always_comb begin
    f_hit = b_hit; f_type = b_type; f_dir = l_dir;
    f_taken = b_hit && (b_type == T_COND ? l_dir : 1'b1);
    f_ras_top = {ras_top, 2'b00};
    if (b_type == T_RET)  f_target = {ras_top, 2'b00};
    else if (is_ind)      f_target = {f_pc[31:TW+2], ind_lo, 2'b00};
    else                  f_target = {f_pc[31:TW+2], b_tgt, 2'b00};
    f_meta = {l_dir, t_hit[2], t_hit[1], t_hit[0], t_u[2], t_u[1], t_u[0], t_ctr[2], t_ctr[1], t_ctr[0],
              t_tag[2], t_tag[1], t_tag[0], t_idx[2], t_idx[1], t_idx[0], bim_rd, i_tag, i_idx, ind_lo, b_type, b_hit};
    f_ckpt = {ras_top, rasp, thr, ghr};
  end

  // -------------------------- speculative state ------------------------------
  wire [HL-1:0]  c_ghr;  wire [HT-1:0] c_thr;  wire [LR-1:0] c_rasp;  wire [29:0] c_top;
  assign {c_top, c_rasp, c_thr, c_ghr} = r_ckpt;
  wire [LR-1:0]  c_rasp_m1 = c_rasp - 1'b1;
  wire sp_cond = f_valid && b_hit && b_type == T_COND;
  wire sp_push = f_valid && b_hit && (b_type == T_CALL || b_type == T_ICALL);
  wire sp_pop  = f_valid && b_hit && b_type == T_RET;
  wire sp_ind  = f_valid && b_hit && is_ind;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ghr <= '0; thr <= '0; rasp <= '0; end
    else if (r_valid) begin
      ghr  <= r_ghr_shift ? {c_ghr[HL-2:0], r_taken} : c_ghr;
      thr  <= r_thr_shift ? ({c_thr[HT-3:0], 2'b00} ^ r_target[2 +: HT]) : c_thr;
      rasp <= r_push ? c_rasp + 1'b1 : r_pop ? c_rasp_m1 : c_rasp;
    end else begin
      if (sp_cond) ghr <= {ghr[HL-2:0], l_dir};
      if (sp_ind)  thr <= {thr[HT-3:0], 2'b00} ^ f_target[2 +: HT];
      if (sp_push) rasp <= rasp + 1'b1; else if (sp_pop) rasp <= rasp_m1;
    end
  end
  always_ff @(posedge clk) begin
    if (r_valid) begin
      ras[c_rasp_m1] <= c_top;                       // undo a wrong-path overwrite of the top entry
      if (r_push) ras[c_rasp] <= r_push_addr[31:2];
    end else if (sp_push) ras[rasp] <= p + 30'd1;
  end

  // ------------------------------ training -----------------------------------
  wire        m_bhit;  wire [2:0] m_btype;  wire [TW-1:0] m_indlo;  wire [LI-1:0] m_iidx;  wire [TI-1:0] m_itag;
  wire [1:0]  m_bim;   wire m_dir;
  wire [LT-1:0] m_idx0, m_idx1, m_idx2;  wire [TT-1:0] m_tag0, m_tag1, m_tag2;
  wire [2:0]  m_ctr0, m_ctr1, m_ctr2;    wire m_u0, m_u1, m_u2, m_h0, m_h1, m_h2;
  assign {m_dir, m_h2, m_h1, m_h0, m_u2, m_u1, m_u0, m_ctr2, m_ctr1, m_ctr0,
          m_tag2, m_tag1, m_tag0, m_idx2, m_idx1, m_idx0, m_bim, m_itag, m_iidx, m_indlo, m_btype, m_bhit} = u_meta;

  function automatic logic [2:0] sat3(input logic [2:0] v, input logic up);
    sat3 = up ? (v == 3'd7 ? v : v + 3'd1) : (v == 3'd0 ? v : v - 3'd1);
  endfunction
  function automatic logic [1:0] sat2(input logic [1:0] v, input logic up);
    sat2 = up ? (v == 2'd3 ? v : v + 2'd1) : (v == 2'd0 ? v : v - 2'd1);
  endfunction

  wire u_br    = u_valid && u_isbr;
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin use_alt <= 4'd8; rstcnt <= '0; end
    else if (u_cond) begin
      rstcnt <= rstcnt + 1'b1;
      if (u_has && u_weak && (u_provp != u_altp))
        use_alt <= (u_altp == u_taken) ? (use_alt == 4'd15 ? use_alt : use_alt + 1'b1) : (use_alt == 4'd0 ? use_alt : use_alt - 1'b1);
    end
  end
  // TAGE tables (no reset on payload bits: keeps them on the small non-reset flop)
  always_ff @(posedge clk) begin
    if (isprov[0] | alloc[0]) tctr0[m_idx0] <= alloc[0] ? ctr_alloc : ctr_new;
    if (isprov[1] | alloc[1]) tctr1[m_idx1] <= alloc[1] ? ctr_alloc : ctr_new;
    if (isprov[2] | alloc[2]) tctr2[m_idx2] <= alloc[2] ? ctr_alloc : ctr_new;
    if (alloc[0]) ttag0[m_idx0] <= m_tag0;
    if (alloc[1]) ttag1[m_idx1] <= m_tag1;
    if (alloc[2]) ttag2[m_idx2] <= m_tag2;
  end
  wire [NT-1:0][LT-1:0] m_idx = {m_idx2, m_idx1, m_idx0};
  always_ff @(posedge clk) begin
    for (int i = 0; i < NT; i++) begin
      if (u_wrap) tu[i] <= '0;                                    // periodic graceful reset (free with flop arrays)
      else if (alloc[i] | decay[i]) tu[i][m_idx[i]] <= 1'b0;
      else if (isprov[i] && (u_provp != u_altp)) tu[i][m_idx[i]] <= (u_provp == u_taken);
    end
  end
  // bimodal
  always_ff @(posedge clk)
    if (u_cond && (!u_has || (!u_pu && u_noalt))) bim[u_pc[2 +: LBIM]] <= sat2(m_bim, u_taken);
  // BTB
  wire [LB-1:0] ub_idx = u_pc[2 +: LB];
  wire          ub_wr  = u_br && u_taken;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) btb_v <= '0;
    else if (u_valid) begin
      if (!u_isbr) btb_v[ub_idx] <= 1'b0;
      else if (u_taken) btb_v[ub_idx] <= 1'b1;
      else if (m_bhit && m_btype != u_type) btb_v[ub_idx] <= 1'b0;
    end
  end
  always_ff @(posedge clk) if (ub_wr) begin
    btb_tag[ub_idx]  <= u_pc[2 + LB +: TBB];
    btb_type[ub_idx] <= u_type;
    btb_tgt[ub_idx]  <= u_target[2 +: TW];
  end
  // ITC
  wire u_ind    = u_br && (u_type == T_IND || u_type == T_ICALL);
  wire u_ind_ok = m_bhit && (m_indlo == u_target[2 +: TW]) && (u_pc[31:TW+2] == u_target[31:TW+2]);
  wire ui_wr    = u_ind && !u_ind_ok;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) itc_v <= '0;
    else if (ui_wr) itc_v[m_iidx] <= 1'b1;
  end
  always_ff @(posedge clk) if (ui_wr) begin
    itc_tag[m_iidx] <= m_itag;
    itc_tgt[m_iidx] <= u_target[2 +: TW];
  end
endmodule
