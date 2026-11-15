// 4-state check of the reset strategy (Icarus 12, unmodified rtl/bp55.sv).
// Ported from review/rtl/tb_bp55_xprop.sv. All non-reset payload flops start as X.
//  - before the clear completes the tables are still X (shows the clear is what fixes it);
//  - while f_busy the outputs must be defined (forced fall-through);
//  - after the clear every output must be defined for many PCs, also after training and
//    speculative updates, and the bimodal / TAGE / RAS arrays must contain no X.
// Result line: "XPROP: <n> failure(s)".
`timescale 1ns/1ps
module tbx;
  localparam logic [2:0] T_COND=0, T_JUMP=1, T_CALL=2, T_RET=3, T_IND=4, T_ICALL=5;
  logic clk=0, rst_n=0, f_fire=0; logic [31:0] f_pc=0;
  logic f_busy, f_hit, f_taken, f_dir; logic [2:0] f_type; logic [31:0] f_target, f_ras_top; logic [103:0] f_meta; logic [66:0] f_ckpt;
  logic r_fire=0; logic [66:0] r_ckpt=0; logic r_ghr_shift=0, r_taken=0, r_push=0, r_pop=0, r_thr_shift=0; logic [31:0] r_push_addr=0, r_target=0;
  logic u_fire=0, u_isbr=0, u_taken=0; logic [31:0] u_pc=0, u_target=0; logic [2:0] u_type=0; logic [103:0] u_meta=0;
  int fails = 0, xcnt;
  bp55 dut(.*);
  task automatic tick(); #1 clk=1; #1 clk=0; endtask
  // XOR-reduction is X if any bit is X/Z (Icarus 12 mis-evaluates $isunknown on this wide
  // concatenation inside a function, so the portable form is used)
  function automatic logic outs_known();
    logic [241:0] v;
    v = {f_busy, f_hit, f_taken, f_dir, f_type, f_target, f_ras_top, f_meta, f_ckpt};
    return (^v) !== 1'bx;
  endfunction
  task automatic check(input string name, input logic cond);
    if (cond === 1'b1) $display("  PASS        %s", name);
    else begin $display("  ** FAIL **  %s", name); fails++; end
  endtask
  task automatic sweep(input string name, input int n);   // look at n PCs, all outputs must be defined
    int bad; bad = 0;
    for (int k = 0; k < n; k++) begin f_pc = 32'h0000_1000 + 4*k; #0.5; if (!outs_known()) bad++; end
    check(name, bad == 0);
  endtask
  task automatic count_x_tables();
    xcnt = 0;
    for (int i = 0; i < 64; i++) begin
      if ($isunknown(dut.bim[i]))   xcnt++;
      if ($isunknown(dut.tctr0[i]) || $isunknown(dut.tctr1[i]) || $isunknown(dut.tctr2[i])) xcnt++;
      if ($isunknown(dut.ttag0[i]) || $isunknown(dut.ttag1[i]) || $isunknown(dut.ttag2[i])) xcnt++;
    end
    for (int i = 0; i < 8; i++) if ($isunknown(dut.ras[i])) xcnt++;
    if ($isunknown({dut.tu0, dut.tu1, dut.tu2})) xcnt++;
  endtask
  initial begin
    int nb;
    tick(); rst_n=1;
    count_x_tables();
    $display("table rows with X right after reset release: %0d", xcnt);
    check("tables start as X (non-reset payload flops)", xcnt > 0);
    nb = 0;
    while (f_busy) begin
      f_pc = 32'h1000 + 4*nb; f_fire = 1; #0.5;
      if (!outs_known()) begin if (fails < 1) $display("    X while busy: hit=%b dir=%b meta=%h", f_hit, f_dir, f_meta); fails++; end
      tick(); nb++;
    end
    f_fire = 0;
    $display("clear finished after %0d cycles", nb);
    check("outputs defined in every busy cycle", fails == 0);
    count_x_tables();
    check("no X left in bimodal / TAGE / u-bit / RAS arrays after the clear", xcnt == 0);
    sweep("after clear, BTB miss: all outputs defined for 256 PCs", 256);
    f_pc=32'h1000; #0.5;
    $display("after clear, BTB miss  : f_hit=%b f_dir=%b f_taken=%b f_ras_top=%h", f_hit, f_dir, f_taken, f_ras_top);
    for (int k=0;k<8;k++) begin   // train a taken conditional branch 8 times
      f_pc=32'h1000; #0.5; u_meta=f_meta; u_fire=1; u_isbr=1; u_pc=32'h1000; u_type=T_COND; u_taken=1; u_target=32'h1100; tick(); u_fire=0;
    end
    // a call, a return and an indirect jump
    f_pc=32'h1240; #0.5; u_meta=f_meta; u_fire=1; u_isbr=1; u_pc=32'h1240; u_type=T_CALL; u_taken=1; u_target=32'h2000; tick(); u_fire=0;
    f_pc=32'h2010; #0.5; u_meta=f_meta; u_fire=1; u_isbr=1; u_pc=32'h2010; u_type=T_RET;  u_taken=1; u_target=32'h1244; tick(); u_fire=0;
    f_pc=32'h1300; #0.5; u_meta=f_meta; u_fire=1; u_isbr=1; u_pc=32'h1300; u_type=T_IND;  u_taken=1; u_target=32'h3000; tick(); u_fire=0;
    f_pc=32'h1000; #0.5;
    $display("after 8 taken trainings: f_hit=%b f_dir=%b f_taken=%b f_target=%h bim=%b", f_hit, f_dir, f_taken, f_target, dut.bim[0][1:0]);
    check("trained conditional predicted taken with defined outputs", f_hit === 1'b1 && f_taken === 1'b1 && f_target === 32'h1100 && outs_known());
    // speculative updates: fire the cond, the call, the indirect
    f_pc=32'h1000; f_fire=1; tick(); f_pc=32'h1240; tick(); f_pc=32'h1300; tick(); f_fire=0; #0.5;
    $display("GHR / THR / RAS pointer after speculative lookups: %h / %h / %0d", dut.ghr, dut.thr, dut.rasp);
    check("speculative state defined", (^{dut.ghr, dut.thr, dut.rasp}) !== 1'bx);
    f_pc=32'h2010; #0.5;
    check("return predicted from the RAS (0x1244)", f_hit === 1'b1 && f_target === 32'h1244);
    sweep("after training: all outputs defined for 256 PCs", 256);
    $display("XPROP: %0d failure(s)", fails);
    $finish;
  end
endmodule
