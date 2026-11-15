// 4-state check of the reset strategy (Icarus). Uses a copy of bp55.sv with line 126
// split per table because Icarus 12 rejects tu[i][t_idx[i]] (see run_xprop.sh).
`timescale 1ns/1ps
module tbx;
  logic clk=0, rst_n=0, f_valid=0; logic [31:0] f_pc=0;
  logic f_hit, f_taken, f_dir; logic [2:0] f_type; logic [31:0] f_target, f_ras_top; logic [91:0] f_meta; logic [66:0] f_ckpt;
  logic r_valid=0; logic [66:0] r_ckpt=0; logic r_ghr_shift=0, r_taken=0, r_push=0, r_pop=0, r_thr_shift=0; logic [31:0] r_push_addr=0, r_target=0;
  logic u_valid=0, u_isbr=0, u_taken=0; logic [31:0] u_pc=0, u_target=0; logic [2:0] u_type=0; logic [91:0] u_meta=0;
  bp55 dut(.*);
  task tick(); #1 clk=1; #1 clk=0; endtask
  initial begin
    tick(); rst_n=1; tick();
    f_pc=32'h1000; #0.5;
    $display("after reset, BTB miss  : f_hit=%b f_dir=%b f_taken=%b f_ras_top=%h", f_hit, f_dir, f_taken, f_ras_top);
    for (int k=0;k<8;k++) begin   // train a taken conditional branch 8 times
      f_pc=32'h1000; #0.5; u_meta=f_meta; u_valid=1; u_isbr=1; u_pc=32'h1000; u_type=0; u_taken=1; u_target=32'h1100; tick(); u_valid=0;
    end
    f_pc=32'h1000; #0.5;
    $display("after 8 taken trainings: f_hit=%b f_dir=%b f_taken=%b f_target=%h bim=%b", f_hit, f_dir, f_taken, f_target, dut.bim[0]);
    f_valid=1; tick(); f_valid=0; #0.5;
    $display("GHR after one speculative lookup: %h", dut.ghr);
    $finish;
  end
endmodule
