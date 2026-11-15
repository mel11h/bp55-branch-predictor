// Directed regression tests for rtl/bp55.sv (v2 interface).
// Ported from review/rtl/tb_bp55_directed.sv (T1-T10, same scenarios) and extended.
// Runs under Verilator (--timing) and Icarus 12; see verif/run.sh.
// Result line: "DONE: <n> failure(s), <k> known-open" ; $fatal on failure is avoided so both
// simulators print the full report; run.sh greps the result line.
//   check()      : must pass
//   check_open() : deferred items (depend on the core); reported, never counted as a failure
`timescale 1ns/1ps
module tb;
  localparam logic [2:0] T_COND=0, T_JUMP=1, T_CALL=2, T_RET=3, T_IND=4, T_ICALL=5;
  logic clk=0, rst_n=0;
  logic f_fire=0; logic [31:0] f_pc=0;
  logic f_busy, f_hit, f_taken, f_dir; logic [2:0] f_type; logic [31:0] f_target, f_ras_top;
  logic [103:0] f_meta; logic [66:0] f_ckpt;
  logic r_fire=0; logic [66:0] r_ckpt=0; logic r_ghr_shift=0, r_taken=0, r_push=0, r_pop=0, r_thr_shift=0;
  logic [31:0] r_push_addr=0, r_target=0;
  logic u_fire=0, u_isbr=0, u_taken=0; logic [31:0] u_pc=0, u_target=0; logic [2:0] u_type=0; logic [103:0] u_meta=0;
  int fails = 0, opens = 0;

  bp55 dut(.*);

  task automatic tick(); #1 clk=1; #1 clk=0; endtask
  task automatic idle();
    f_fire=0; r_fire=0; u_fire=0; r_ghr_shift=0; r_taken=0; r_push=0; r_pop=0; r_thr_shift=0;
  endtask
  // single-cycle accepted lookup; returns the outputs seen in the f_fire cycle
  task automatic lookup(input logic [31:0] pc, output logic [103:0] meta, output logic [66:0] ck);
    idle(); f_fire=1; f_pc=pc; #0.5; meta=f_meta; ck=f_ckpt; tick(); f_fire=0;
  endtask
  task automatic peek(input logic [31:0] pc); // combinational look, no f_fire
    idle(); f_pc=pc; #0.5;
  endtask
  task automatic train(input logic [31:0] pc, input logic isbr, input logic [2:0] ty, input logic tk,
                       input logic [31:0] tgt, input logic [103:0] meta);
    idle(); u_fire=1; u_isbr=isbr; u_pc=pc; u_type=ty; u_taken=tk; u_target=tgt; u_meta=meta; tick(); u_fire=0;
  endtask
  task automatic flush(input logic [66:0] ck); // r_fire with no history / stack operation
    idle(); r_fire=1; r_ckpt=ck; tick(); idle();
  endtask
  task automatic check(input string name, input logic cond);
    if (cond === 1'b1) $display("  PASS        %s", name);
    else begin $display("  ** FAIL **  %s", name); fails++; end
  endtask
  task automatic check_open(input string name, input logic cond);
    opens++;
    if (cond === 1'b1) $display("  KNOWN-OPEN  %s (passes in this scenario)", name);
    else               $display("  KNOWN-OPEN  %s (fails as expected; deferred until the core is chosen)", name);
  endtask
  // learn a taken branch/jump into the BTB (lookup + train)
  task automatic learn(input logic [31:0] pc, input logic [2:0] ty, input logic [31:0] tgt);
    logic [103:0] m;
    peek(pc); m = f_meta; train(pc, 1, ty, 1, tgt, m);
  endtask
  task automatic do_reset();
    idle(); rst_n=0; tick(); rst_n=1;
    while (f_busy) tick();
  endtask

  initial begin
    logic [103:0] m, m2; logic [66:0] c, c2, c3; logic [2:0] rp0; logic [27:0] g0; logic [10:0] rc0;
    int nb; logic forced;

    // ---------------------------------------------------------------- T0 (C)
    $display("T0: post-reset clear: f_busy length, forced outputs, inputs ignored while busy");
    idle(); rst_n=0; tick(); rst_n=1;
    nb = 0; forced = 1;
    while (f_busy && nb < 1000) begin
      f_pc = 32'h1000 + 4*nb; f_fire = 1;
      // a training message for a taken JAL and a redirect with a non-zero checkpoint: both must be ignored
      u_fire=1; u_isbr=1; u_pc=32'h2000; u_type=T_JUMP; u_taken=1; u_target=32'h3000; u_meta='0;
      r_fire=(nb==10); r_ckpt={30'h123, 3'd5, 6'h2a, 28'h0abcdef}; r_push=1; r_push_addr=32'h5000;
      #0.5; if (f_hit !== 1'b0 || f_taken !== 1'b0 || f_dir !== 1'b0 || f_type !== 3'd0 || f_ras_top !== 32'd0) forced = 0;
      tick(); nb++;
    end
    idle();
    $display("    f_busy cycles after reset release = %0d", nb);
    check("clear takes 64 cycles", nb == 64);
    check("predictions forced to fall-through while busy", forced);
    peek(32'h2000);
    check("training during the clear is ignored", f_hit == 1'b0);
    check("redirect during the clear is ignored", dut.ghr == '0 && dut.rasp == '0 && dut.thr == '0);
    check("u-bit reset counter not advanced while busy", dut.rstcnt == '0);
    do_reset();

    // ---------------------------------------------------------------- T1 (A)
    $display("T1: lookup held in IF1 for 2 cycles (f_fire=0) then accepted, on a BTB-hit CALL");
    learn(32'h0000_1000, T_CALL, 32'h0000_4000);
    rp0 = dut.rasp;
    idle(); f_pc=32'h0000_1000; #0.5; c = f_ckpt; m = f_meta; tick(); #0.5; c2 = f_ckpt; m2 = f_meta;
    check("held lookup does not push the RAS", dut.rasp == rp0);
    tick(); f_fire=1; #0.5; c3 = f_ckpt; tick(); idle();
    $display("    rasp before=%0d after hold+fire=%0d ; f_ckpt.rasp held=%0d,%0d fire=%0d",
             rp0, dut.rasp, c[36:34], c2[36:34], c3[36:34]);
    check("one call held 2 cycles pushes the RAS once", dut.rasp == rp0 + 3'd1);
    check("f_ckpt stable while the same instruction sits in IF1", c == c2 && c2 == c3);
    check("f_meta stable while held (no training in between)", m == m2);
    learn(32'h0000_2000, T_COND, 32'h0000_2100);
    flush({f_ckpt[66:28], 28'h0000005});               // seed GHR = 0x5, keep the RAS state
    g0 = dut.ghr;
    idle(); f_pc=32'h0000_2000; tick(); tick(); tick();
    check("held COND lookup does not shift the GHR", dut.ghr == g0);
    f_fire=1; #0.5; forced = f_dir; tick(); idle();
    check("accepted COND lookup shifts the GHR exactly once", dut.ghr == {g0[26:0], forced});
    do_reset();

    // ---------------------------------------------------------------- T2 (deferred)
    $display("T2: lookup in the same cycle as r_fire (core that fetches the redirect target in the redirect cycle)");
    learn(32'h0000_1000, T_CALL, 32'h0000_4000);
    learn(32'h0000_2008, T_COND, 32'h0000_3000);
    lookup(32'h0000_0800, m, c);
    lookup(32'h0000_1000, m2, c2);
    rp0 = c[36:34];
    idle(); r_fire=1; r_ckpt=c; r_target=32'h0000_1000;
    f_fire=1; f_pc=32'h0000_1000; #0.5; m2 = f_meta; c2 = f_ckpt; tick(); idle();
    $display("    restored rasp should be %0d, then +1 for the call fetched this cycle; got rasp=%0d; f_ckpt.rasp seen=%0d (correct %0d)",
             rp0, dut.rasp, c2[36:34], rp0);
    check_open("call looked up in the redirect cycle is pushed", dut.rasp == rp0 + 3'd1);
    check_open("f_ckpt in the redirect cycle reflects the restored state", c2[36:34] == rp0);
    do_reset();

    // ---------------------------------------------------------------- T3 (B)
    $display("T3: u_isbr=0 training for a PC that did NOT hit the BTB");
    learn(32'h0000_1000, T_JUMP, 32'h0000_4000);
    peek(32'h0000_1200); m = f_meta;                    // same index (pc[8:2]), different tag (pc[9]): miss
    $display("    lookup 0x1200: f_hit=%0d (meta b_hit=%0d)", f_hit, m[0]);
    train(32'h0000_1200, 0, T_COND, 0, 0, m);
    peek(32'h0000_1000);
    check("unrelated JAL at 0x1000 still in the BTB", f_hit == 1);
    $display("T3b: phantom message whose entry was replaced between lookup and training");
    peek(32'h0002_1000); m = f_meta;                    // alias of 0x1000: hits
    check("alias 0x21000 hits the 0x1000 entry", f_hit == 1 && m[0] == 1);
    learn(32'h0000_1200, T_JUMP, 32'h0000_5000);        // replaces the entry (same index, other tag)
    train(32'h0002_1000, 0, T_COND, 0, 0, m);           // late phantom message for the old lookup
    peek(32'h0000_1200);
    check("replacing entry survives the stale phantom message", f_hit == 1 && f_target == 32'h0000_5000);
    $display("T3c: type-change invalidation is also tag-checked");
    peek(32'h0000_1200); m = f_meta;                    // hit, type JUMP
    learn(32'h0000_1000, T_JUMP, 32'h0000_4000);        // entry now belongs to 0x1000
    train(32'h0000_1200, 1, T_COND, 0, 32'h0000_1300, m);  // 0x1200 resolves as a not-taken COND
    peek(32'h0000_1000);
    check("entry of 0x1000 survives a type-change message for 0x1200", f_hit == 1);
    do_reset();

    // ---------------------------------------------------------------- T4 (F contract)
    $display("T4: BTB tag alias (pc ^ 0x20000) and phantom-COND history pollution");
    learn(32'h0000_1000, T_COND, 32'h0000_1100);
    peek(32'h0002_1000);
    $display("    alias 0x21000: f_hit=%0d f_type=%0d f_dir=%0d f_taken=%0d", f_hit, f_type, f_dir, f_taken);
    check("non-branch at 0x21000 hits (expected alias behaviour)", f_hit == 1);
    flush({30'd0, 3'd0, 6'd0, 28'h0000005});           // seed GHR=0x5
    g0 = dut.ghr;
    lookup(32'h0002_1000, m, c);
    $display("    ghr before=%07h after phantom lookup=%07h (speculative shift, documented)", g0, dut.ghr);
    check("phantom COND lookup shifts the GHR (core must repair from ID; the model charges 2 cycles)", dut.ghr != g0);
    flush(c);
    check("ID repair (flush to the phantom's checkpoint) restores the GHR", dut.ghr == g0);
    train(32'h0002_1000, 0, T_COND, 0, 0, m);
    peek(32'h0002_1000);
    check("phantom invalidation removes the aliased entry", f_hit == 0);
    do_reset();

    // ---------------------------------------------------------------- T5 (E)
    $display("T5: targets outside the 1 MiB region");
    learn(32'h000F_FFFC, T_JUMP, 32'h000F_F000);
    peek(32'h000F_FFFC);
    check("near direct target predicted", f_hit == 1 && f_target == 32'h000F_F000);
    learn(32'h000F_FFFC, T_JUMP, 32'h0010_0010);
    peek(32'h000F_FFFC);
    $display("    JAL 0x000FFFFC -> 0x00100010 : f_hit=%0d f_target=%08h", f_hit, f_target);
    check("far direct target is not stored and the stale entry is dropped (no wrong prediction)", f_hit == 0);
    learn(32'h0800_0100, T_ICALL, 32'h2000_0040);
    peek(32'h0800_0100); m = f_meta;
    $display("    ICALL 0x08000100 -> 0x20000040 after one training: f_target=%08h", f_target);
    check("far indirect target predicted after one training", f_hit == 1 && f_taken == 1 && f_target == 32'h2000_0040);
    idle(); u_fire=1; u_isbr=1; u_pc=32'h0800_0100; u_type=T_ICALL; u_taken=1; u_target=32'h2000_0040; u_meta=m; #0.5;
    check("correctly predicted far indirect does not rewrite the ITC", dut.ui_wr == 1'b0);
    tick(); idle();
    learn(32'h2000_0204, T_RET, 32'h0800_0104);
    lookup(32'h0800_0100, m, c);                       // ICALL: speculative push of 0x08000104
    peek(32'h2000_0204);
    check("return across regions predicted from the RAS", f_hit == 1 && f_target == 32'h0800_0104);
    learn(32'h000F_FFF8, T_CALL, 32'h000F_0000);
    lookup(32'h000F_FFF8, m, c);                       // CALL: push 0x000FFFFC
    lookup(32'h000F_FFFC, m, c);                       // non-branch (missed): nothing
    learn(32'h000F_0010, T_RET, 0);
    peek(32'h000F_0010);
    check("RAS keeps all 30 bits (return address 0x000FFFFC)", f_target == 32'h000F_FFFC);
    do_reset();

    // ---------------------------------------------------------------- T6 (D)
    $display("T6: training payload held 2 cycles (EX/MEM stall) with a single u_fire pulse");
    learn(32'h0000_1000, T_COND, 32'h0000_1100);
    peek(32'h0000_1000); m = f_meta; rc0 = dut.rstcnt;
    idle(); u_fire=1; u_isbr=1; u_pc=32'h1000; u_type=T_COND; u_taken=1; u_target=32'h1100; u_meta=m; tick();
    u_fire=0; tick(); idle();
    $display("    rstcnt before=%0d after=%0d", rc0, dut.rstcnt);
    check("one branch counted once by the u-bit reset counter", dut.rstcnt == rc0 + 11'd1);
    rc0 = dut.rstcnt;
    idle(); u_fire=1; u_isbr=1; u_pc=32'h1000; u_type=T_COND; u_taken=1; u_target=32'h1100; u_meta=m; tick(); tick(); idle();
    check("contract: every u_fire cycle is one message (two cycles = two messages)", dut.rstcnt == rc0 + 11'd2);
    do_reset();

    // ---------------------------------------------------------------- T7 (deferred)
    $display("T7: RAS top-only repair vs. 3 wrong-path RAS ops (needs >2 younger lookups, e.g. a fetch queue)");
    learn(32'h0000_1004, T_CALL, 32'h0000_4000);
    learn(32'h0000_1008, T_CALL, 32'h0000_4100);
    learn(32'h0000_500C, T_RET,  32'h0000_0000);
    learn(32'h0000_5010, T_RET,  32'h0000_0000);
    lookup(32'h0000_1004, m, c); lookup(32'h0000_1008, m, c);
    lookup(32'h0000_0818, m, c);
    lookup(32'h0000_500C, m2, c2); lookup(32'h0000_5010, m2, c2); lookup(32'h0000_1008, m2, c2);
    flush(c);
    lookup(32'h0000_500C, m2, c2);
    peek(32'h0000_500C);
    $display("    after repair: 2nd RET target=%08h (correct 0x00001008)", f_target);
    check_open("second-level return address survives wrong-path pop,pop,push", f_target == 32'h0000_1008);
    do_reset();

    // ---------------------------------------------------------------- T8-T10
    $display("T8: same three wrong-path ops but only 2 younger lookups (exact 6-stage, no fetch queue)");
    learn(32'h0000_1004, T_CALL, 32'h0000_4000); learn(32'h0000_1008, T_CALL, 32'h0000_4100);
    learn(32'h0000_500C, T_RET, 0); learn(32'h0000_1014, T_CALL, 32'h0000_4200);
    lookup(32'h0000_1004, m, c); lookup(32'h0000_1008, m, c); lookup(32'h0000_0818, m, c);
    lookup(32'h0000_500C, m2, c2); lookup(32'h0000_1014, m2, c2);
    flush(c);
    lookup(32'h0000_500C, m2, c2); peek(32'h0000_500C);
    check("2-deep wrong path: RAS fully repaired", f_target == 32'h0000_1008 && c2[66:37] == (32'h100C >> 2));
    $display("T9: back-to-back redirects, older one second (EX after ID)");
    lookup(32'h0000_0818, m, c); lookup(32'h0000_1014, m2, c2);
    idle(); r_fire=1; r_ckpt=c2; r_push=1; r_push_addr=32'h1018; tick();
    r_ckpt=c; r_push=0; tick(); idle();
    check("older redirect after younger restores older checkpoint", dut.rasp == c[36:34] && dut.ghr == c[27:0]);
    $display("T10: r_fire held 2 cycles is idempotent");
    lookup(32'h0000_0818, m, c);
    idle(); r_fire=1; r_ckpt=c; r_ghr_shift=1; r_taken=1; r_push=1; r_push_addr=32'h081C; tick(); tick(); idle();
    check("held redirect applies its op once", dut.rasp == c[36:34] + 3'd1 && dut.ghr == {c[26:0],1'b1});
    do_reset();

    // ---------------------------------------------------------------- T11 (flush)
    $display("T11: flush (r_fire, no operation) restores a checkpoint after wrong-path lookups");
    learn(32'h0000_1000, T_CALL, 32'h0000_4000);
    learn(32'h0000_4000, T_COND, 32'h0000_4100);
    learn(32'h0000_4010, T_ICALL, 32'h0000_6040);
    lookup(32'h0000_0900, m, c);                       // the trapping instruction (checkpoint c)
    lookup(32'h0000_1000, m2, c2); lookup(32'h0000_4000, m2, c2); lookup(32'h0000_4010, m2, c2);
    check("wrong-path lookups changed GHR / THR / RAS pointer", dut.rasp != c[36:34] && dut.thr != c[33:28]);
    flush(c);
    peek(32'h0000_0900);
    check("flush restores GHR, THR, RAS pointer and RAS top", f_ckpt == c);

    $display("DONE: %0d failure(s), %0d known-open", fails, opens);
    $finish;
  end
endmodule
