// Directed tests for rtl/bp55.sv: scenarios the trace-driven cosim cannot produce.
// Build/run: see review/rtl/run.sh
`timescale 1ns/1ps
module tb;
  localparam logic [2:0] T_COND=0, T_JUMP=1, T_CALL=2, T_RET=3, T_IND=4, T_ICALL=5;
  logic clk=0, rst_n=0;
  logic f_valid=0; logic [31:0] f_pc=0;
  logic f_hit, f_taken, f_dir; logic [2:0] f_type; logic [31:0] f_target, f_ras_top;
  logic [91:0] f_meta; logic [66:0] f_ckpt;
  logic r_valid=0; logic [66:0] r_ckpt=0; logic r_ghr_shift=0, r_taken=0, r_push=0, r_pop=0, r_thr_shift=0;
  logic [31:0] r_push_addr=0, r_target=0;
  logic u_valid=0, u_isbr=0, u_taken=0; logic [31:0] u_pc=0, u_target=0; logic [2:0] u_type=0; logic [91:0] u_meta=0;
  int fails = 0;

  bp55 dut(.*);

  task automatic tick(); #1 clk=1; #1 clk=0; endtask
  task automatic idle(); f_valid=0; r_valid=0; u_valid=0; endtask
  // single-cycle lookup; returns the outputs seen in that cycle
  task automatic lookup(input logic [31:0] pc, output logic [91:0] meta, output logic [66:0] ck);
    idle(); f_valid=1; f_pc=pc; #0.5; meta=f_meta; ck=f_ckpt; tick(); f_valid=0;
  endtask
  task automatic peek(input logic [31:0] pc); // combinational look, no f_valid
    idle(); f_pc=pc; #0.5;
  endtask
  task automatic train(input logic [31:0] pc, input logic isbr, input logic [2:0] ty, input logic tk,
                       input logic [31:0] tgt, input logic [91:0] meta);
    idle(); u_valid=1; u_isbr=isbr; u_pc=pc; u_type=ty; u_taken=tk; u_target=tgt; u_meta=meta; tick(); u_valid=0;
  endtask
  task automatic check(input string name, input logic cond);
    if (cond) $display("  PASS-EXPECTED  %s", name);
    else begin $display("  ** DEFECT **   %s", name); fails++; end
  endtask
  // learn a direct taken branch/jump into the BTB (lookup + train)
  task automatic learn(input logic [31:0] pc, input logic [2:0] ty, input logic [31:0] tgt);
    logic [91:0] m; logic [66:0] c;
    peek(pc); m = f_meta; train(pc, 1, ty, 1, tgt, m);
  endtask
  task automatic do_reset(); idle(); rst_n=0; tick(); rst_n=1; tick(); endtask

  initial begin
    logic [91:0] m, m2; logic [66:0] c, c2; logic [2:0] rp0; logic [27:0] g0; logic [10:0] rc0; logic [3:0] ua0;
    logic [6:0] i0;
    do_reset();

    // ---------------------------------------------------------------- T1
    $display("T1: f_valid held high across a 2-cycle IF1 stall on a BTB-hit CALL / COND");
    learn(32'h0000_1000, T_CALL, 32'h0000_4000);
    rp0 = dut.rasp;
    idle(); f_valid=1; f_pc=32'h0000_1000; #0.5; c = f_ckpt; tick(); #0.5; c2 = f_ckpt; tick(); f_valid=0;
    $display("    rasp before=%0d after 2 stalled cycles=%0d ; f_ckpt.rasp cycle1=%0d cycle2=%0d",
             rp0, dut.rasp, c[36:34], c2[36:34]);
    check("one call held 2 cycles pushes the RAS once", dut.rasp == rp0 + 3'd1);
    check("f_ckpt stable while the same instruction sits in IF1", c == c2);
    do_reset();

    // ---------------------------------------------------------------- T2
    $display("T2: lookup in the same cycle as r_valid (core that fetches the redirect target in the redirect cycle)");
    learn(32'h0000_1000, T_CALL, 32'h0000_4000);      // call at 0x1000
    learn(32'h0000_2008, T_COND, 32'h0000_3000);      // cond at 0x2008 (wrong-path pollution source)
    lookup(32'h0000_0800, m, c);                       // X: some branch we will mispredict; c = good checkpoint
    lookup(32'h0000_1000, m2, c2);                     // wrong-path call: pushes RAS
    rp0 = c[36:34];
    // redirect for X, and the core presents the (correct-path) redirect target = the call at 0x1000 in the same cycle
    idle(); r_valid=1; r_ckpt=c; r_target=32'h0000_1000;
    f_valid=1; f_pc=32'h0000_1000; #0.5; m2 = f_meta; c2 = f_ckpt; tick(); idle();
    $display("    restored rasp should be %0d, then +1 for the call fetched this cycle; got rasp=%0d; f_ckpt.rasp seen=%0d (correct %0d)",
             rp0, dut.rasp, c2[36:34], rp0);
    check("call looked up in the redirect cycle is pushed", dut.rasp == rp0 + 3'd1);
    check("f_ckpt in the redirect cycle reflects the restored state", c2[36:34] == rp0);
    do_reset();

    // ---------------------------------------------------------------- T3
    $display("T3: u_valid with u_isbr=0 for a PC that did NOT hit the BTB");
    learn(32'h0000_1000, T_JUMP, 32'h0000_4000);
    peek(32'h0000_1200); m = f_meta;                    // same index (pc[8:2]), different tag (pc[9]): miss
    $display("    lookup 0x1200: f_hit=%0d (meta b_hit=%0d)", f_hit, m[0]);
    train(32'h0000_1200, 0, T_COND, 0, 0, m);          // core reports "non-branch" for an ordinary instruction
    peek(32'h0000_1000);
    check("unrelated JAL at 0x1000 still in the BTB", f_hit == 1);
    do_reset();

    // ---------------------------------------------------------------- T4
    $display("T4: BTB tag alias (pc ^ 0x20000) and phantom-COND history pollution");
    learn(32'h0000_1000, T_COND, 32'h0000_1100);
    peek(32'h0002_1000);
    $display("    alias 0x21000: f_hit=%0d f_type=%0d f_dir=%0d f_taken=%0d", f_hit, f_type, f_dir, f_taken);
    check("non-branch at 0x21000 hits (expected alias behaviour; README says path untested)", f_hit == 1);
    idle(); r_valid=1; r_ckpt={30'd0,3'd0,6'd0,28'h0000005}; tick(); idle();   // seed GHR=0x5 via a redirect
    g0 = dut.ghr;
    lookup(32'h0002_1000, m, c);
    $display("    ghr before=%07h after non-branch lookup=%07h (fetch PC is right if f_dir=0, yet history changed)", g0, dut.ghr);
    check("non-branch lookup leaves GHR alone (it does not -> core MUST flush+repair even when fetch was right)", dut.ghr == g0);
    train(32'h0002_1000, 0, T_COND, 0, 0, m);
    peek(32'h0002_1000);
    check("phantom invalidation removes the aliased entry", f_hit == 0);
    do_reset();

    // ---------------------------------------------------------------- T5
    $display("T5: 18-bit stored target, branch crossing a 1 MiB boundary");
    learn(32'h000F_FFFC, T_JUMP, 32'h0010_0010);
    peek(32'h000F_FFFC);
    $display("    JAL 0x000FFFFC -> 0x00100010 : f_target=%08h", f_target);
    check("direct target across 1 MiB boundary predicted", f_target == 32'h0010_0010);
    // indirect call from flash-like region to RAM-like region
    learn(32'h0800_0100, T_ICALL, 32'h2000_0040);
    for (int k = 0; k < 4; k++) begin
      peek(32'h0800_0100); m = f_meta;
      train(32'h0800_0100, 1, T_ICALL, 1, 32'h2000_0040, m);
    end
    peek(32'h0800_0100);
    $display("    ICALL 0x08000100 -> 0x20000040 after repeated training: f_target=%08h", f_target);
    check("far indirect target predicted after training", f_target == 32'h2000_0040);
    do_reset();

    // ---------------------------------------------------------------- T6
    $display("T6: u_valid held 2 cycles (EX/MEM stall) for one conditional branch");
    learn(32'h0000_1000, T_COND, 32'h0000_1100);
    peek(32'h0000_1000); m = f_meta; rc0 = dut.rstcnt;
    idle(); u_valid=1; u_isbr=1; u_pc=32'h1000; u_type=T_COND; u_taken=1; u_target=32'h1100; u_meta=m; tick(); tick(); idle();
    $display("    rstcnt before=%0d after=%0d", rc0, dut.rstcnt);
    check("one branch counted once by the u-bit reset counter", dut.rstcnt == rc0 + 11'd1);
    do_reset();

    // ---------------------------------------------------------------- T7
    $display("T7: RAS top-only repair vs. 3 wrong-path RAS ops (needs >2 younger lookups, e.g. a fetch queue)");
    learn(32'h0000_1004, T_CALL, 32'h0000_4000);       // CALL A at 0x1004 -> ret addr 0x1008
    learn(32'h0000_1008, T_CALL, 32'h0000_4100);       // CALL B at 0x1008 -> ret addr 0x100C
    learn(32'h0000_500C, T_RET,  32'h0000_0000);       // RET at 0x500C
    learn(32'h0000_5010, T_RET,  32'h0000_0000);       // RET at 0x5010
    lookup(32'h0000_1004, m, c); lookup(32'h0000_1008, m, c);   // RAS = [0x1008, 0x100C], rasp=2
    lookup(32'h0000_0818, m, c);                       // X (mispredicted later); ckpt rasp=2 top=0x100C
    lookup(32'h0000_500C, m2, c2); lookup(32'h0000_5010, m2, c2); lookup(32'h0000_1008, m2, c2); // wrong path: ret, ret, call
    idle(); r_valid=1; r_ckpt=c; tick(); idle();
    lookup(32'h0000_500C, m2, c2);                     // pop -> top 0x100C restored correctly
    peek(32'h0000_500C);
    $display("    after repair: 1st RET predicted earlier, 2nd RET target=%08h (correct 0x00001008)", f_target);
    check("second-level return address survives wrong-path pop,pop,push", f_target == 32'h0000_1008);
    do_reset();

    // ---------------------------------------------------------------- T8
    $display("T8: same three wrong-path ops but only 2 younger lookups (exact 6-stage, no fetch queue)");
    learn(32'h0000_1004, T_CALL, 32'h0000_4000); learn(32'h0000_1008, T_CALL, 32'h0000_4100);
    learn(32'h0000_500C, T_RET, 0); learn(32'h0000_1014, T_CALL, 32'h0000_4200);
    lookup(32'h0000_1004, m, c); lookup(32'h0000_1008, m, c); lookup(32'h0000_0818, m, c);
    lookup(32'h0000_500C, m2, c2); lookup(32'h0000_1014, m2, c2);   // wrong path: ret, call (2 lookups)
    idle(); r_valid=1; r_ckpt=c; tick(); idle();
    lookup(32'h0000_500C, m2, c2); peek(32'h0000_500C);
    check("2-deep wrong path: RAS fully repaired", f_target == 32'h0000_1008 && c2[66:37] == (32'h100C >> 2));
    $display("T9: back-to-back redirects, older one second (EX after ID)");
    lookup(32'h0000_0818, m, c); lookup(32'h0000_1014, m2, c2);
    idle(); r_valid=1; r_ckpt=c2; r_push=1; r_push_addr=32'h1018; tick();
    r_ckpt=c; r_push=0; tick(); idle();
    check("older redirect after younger restores older checkpoint", dut.rasp == c[36:34] && dut.ghr == c[27:0]);
    $display("T10: r_valid held 2 cycles is idempotent");
    lookup(32'h0000_0818, m, c);
    idle(); r_valid=1; r_ckpt=c; r_ghr_shift=1; r_taken=1; r_push=1; r_push_addr=32'h081C; tick(); tick(); idle();
    check("held redirect applies its op once", dut.rasp == c[36:34] + 3'd1 && dut.ghr == {c[26:0],1'b1});
    r_ghr_shift=0; r_taken=0; r_push=0;

    $display("DONE: %0d defect(s) demonstrated", fails);
    $finish;
  end
endmodule
