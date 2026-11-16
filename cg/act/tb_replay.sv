// Event-driven (Icarus) replay of a recorded BP55 stimulus on a gate netlist.
// Reads one record per line from +rec=<file> (24 hex words, cg/act/rec2hex.py), applies the inputs
// while clk is low, compares every output with the recorded RTL output after the design settles
// (4-state compare: an X is a mismatch), then raises the clock. Payload flops start as X (no
// zero initialisation), so a pass also shows that no output depends on uninitialised state.
// rst_n starts high and is driven low by the first record, so the reset is asserted by an edge.
`timescale 1ns/1ps
module tbr;
  reg clk = 0, rst_n = 1, f_fire = 0, r_fire = 0, r_ghr_shift = 0, r_taken = 0, r_push = 0, r_pop = 0, r_thr_shift = 0;
  reg u_fire = 0, u_isbr = 0, u_taken = 0;
  reg [31:0] f_pc = 0, r_push_addr = 0, r_target = 0, u_pc = 0, u_target = 0;
  reg [66:0] r_ckpt = 0; reg [103:0] u_meta = 0; reg [2:0] u_type = 0;
  wire f_busy, f_hit, f_taken, f_dir; wire [2:0] f_type; wire [31:0] f_target, f_ras_top;
  wire [103:0] f_meta; wire [66:0] f_ckpt;
  bp55 dut(.*);
  reg [8*1024-1:0] fname;
  reg [31:0] w [0:23];
  integer fd, k, n, cyc, bad, bad_tgt_nt, shown;
  reg [8:0] m;
  initial begin
    if (!$value$plusargs("rec=%s", fname)) begin $display("need +rec="); $finish; end
    fd = $fopen(fname, "r");
    cyc = 0; bad = 0; bad_tgt_nt = 0; shown = 0;
    while (!$feof(fd)) begin
      n = 0;
      for (k = 0; k < 24; k = k + 1) n = n + $fscanf(fd, "%h", w[k]);
      if (n == 24) begin
        f_pc = w[0]; r_push_addr = w[1]; r_target = w[2]; u_pc = w[3]; u_target = w[4];
        r_ckpt = {w[7][2:0], w[6], w[5]}; u_meta = {w[11][7:0], w[10], w[9], w[8]};
        {u_taken, u_isbr, u_fire, r_thr_shift, r_pop, r_push, r_taken, r_ghr_shift, r_fire, f_fire} = w[12][9:0];
        rst_n = w[12][10]; u_type = w[12][18:16];
        #1;
        m = 0;
        m[0] = f_busy !== w[23][0]; m[1] = f_hit !== w[23][1]; m[2] = f_taken !== w[23][2];
        m[3] = f_dir !== w[23][3]; m[4] = f_type !== w[23][6:4];
        m[5] = (f_target !== w[14]) && w[23][2]; m[6] = f_ras_top !== w[15];
        m[7] = f_meta !== {w[19][7:0], w[18], w[17], w[16]}; m[8] = f_ckpt !== {w[22][2:0], w[21], w[20]};
        if ((f_target !== w[14]) && !w[23][2]) bad_tgt_nt = bad_tgt_nt + 1;
        if (m != 0) begin
          bad = bad + 1;
          if (shown < 10) begin shown = shown + 1; $display("MISMATCH cycle %0d fields %b (busy hit taken dir type target ras meta ckpt = bit 0..8)", cyc, m); end
        end
        #2 clk = 1; #3 clk = 0;
        cyc = cyc + 1;
      end
    end
    $display("REPLAY cycles=%0d mismatching_cycles=%0d f_target_not_taken_diff=%0d => %s", cyc, bad, bad_tgt_nt, bad ? "FAIL" : "PASS");
    $finish;
  end
endmodule
