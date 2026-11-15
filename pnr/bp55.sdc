# BP55 block-level constraints, v1 (replaces the original file, now pnr/bp55_legacy.sdc).
#
# Context. BP55 sits in IF1 of a six-stage in-order core (IF1 IF2 ID EX MEM WB) and is
# clocked by the core clock. The f_pc -> f_taken/f_target lookup is combinational, so
# the loop PC flop -> BP55 -> next-PC mux -> PC flop must fit in one cycle. Every other
# port is launched or captured by a core pipeline flop.
#
# How IO delays are referenced. All delays below are external path delays between this
# block's pin and a flop in the core that hangs off the same clock tree as BP55's own
# flops. To time them that way the delays are given relative to the clock arrival at one
# of BP55's own flop clock pins (-reference_pin), chosen after CTS as the flop with the
# median slow-corner insertion delay (pnr/flow/common.tcl: pick_io_ref_pin). This takes
# the insertion delay out of the IO paths in every corner without a per-corner number,
# which a virtual clock with set_clock_latency would need (one SDC serves all three
# corners in OpenROAD). Before CTS the clock is ideal, the reference pin would see zero
# latency, and the plain -clock form below is equivalent.
#
# Budgets are slow-corner (1.08 V, 125 C) estimates of the external logic, written as
# absolute delays, not as fractions of the period, because the logic outside does not
# get faster when the period changes. The same numbers apply in tt and ff (pessimistic
# for setup there). Minimum (hold) values are the fast-corner clock-to-Q of a core flop
# with no logic after it, 0.10 ns, for every input; 0.0 ns for every output (the
# capturing core flop's hold time is covered by about one wire of delay outside).
#
# Reference cell delays used (ICsprout55 H7CR, ss_rcworst_1p08_125, from the Liberty
# and from zero-wire STA of the synthesis netlist): flop clock-to-Q 0.30-0.45 ns,
# 2:1 mux 0.20-0.25 ns, flop setup 0.10-0.15 ns, a 32-bit compare or add 0.8-1.0 ns.

set clk_period [expr {[info exists ::env(BP55_PERIOD)] ? $::env(BP55_PERIOD) : 6.0}]
create_clock -name clk -period $clk_period [get_ports clk]

# Setup: 0.08 ns cycle-to-cycle jitter of an on-chip PLL plus 0.12 ns for what this
# flow does not model (no extracted parasitics, no on-chip variation; see the run notes).
# Clock skew is not in here: the clock is propagated after CTS.
set_clock_uncertainty -setup 0.20 [get_clocks clk]
# Hold: no jitter between launch and capture of the same edge; 0.05 ns for skew
# estimation error of the unextracted clock tree.
set_clock_uncertainty -hold 0.05 [get_clocks clk]

set bp55_ref {}
if {[info exists ::bp55_io_ref_pin] && $::bp55_io_ref_pin ne ""} {
  set bp55_ref [list -reference_pin [get_pins $::bp55_io_ref_pin]]
}
# The same file serves v1 (rtl/bp55.sv at 8ff8f15: f_valid, r_valid, u_valid, 92-bit
# meta) and v2 (30f66e0: f_fire, r_fire, u_fire, f_busy, 104-bit meta). Port names that
# do not exist in the loaded netlist are skipped; wildcards cover the bus widths.
proc bp55_in {max min ports} {
  upvar bp55_ref ref
  set p [get_ports -quiet $ports]
  if {[llength $p] == 0} return
  set_input_delay -max $max -clock clk {*}$ref $p
  set_input_delay -min $min -clock clk {*}$ref $p
}
proc bp55_out {max min ports} {
  upvar bp55_ref ref
  set p [get_ports -quiet $ports]
  if {[llength $p] == 0} return
  set_output_delay -max $max -clock clk {*}$ref $p
  set_output_delay -min $min -clock clk {*}$ref $p
}

# ---- inputs -------------------------------------------------------------------------
# f_pc, f_valid (v1): straight from the PC register and the fetch-valid flop: clock-to-Q
# of a high-fanout flop (0.45) plus the buffer and wire from the PC to the block edge (0.25).
bp55_in 0.70 0.10 {f_pc[*] f_valid}
# f_fire (v2): the v2 contract defines it as valid & ~stall & ~kill of IF1, and kill is
# the EX/ID redirect, so it arrives as late as the redirect controls below.
bp55_in 2.00 0.10 {f_fire}
# r_valid, r_taken, r_ghr_shift, r_thr_shift, r_push, r_pop: decided by EX branch
# resolution: clock-to-Q (0.4) + operand forwarding mux (0.3) + 32-bit compare (0.9)
# + ID/EX redirect priority select (0.4).
# (r_valid in v1, r_fire in v2: one pulse per redirect, same source.)
bp55_in 2.00 0.10 {r_valid r_fire r_taken r_ghr_shift r_thr_shift r_push r_pop}
# r_ckpt: carried down the pipeline in a register: clock-to-Q (0.4) + ID/EX source
# select mux (0.25) + wire (0.15).
bp55_in 0.80 0.10 {r_ckpt[*]}
# r_target, r_push_addr: outputs of the EX target adder / the PC+4 of the call:
# clock-to-Q (0.4) + 32-bit add (0.9) + select (0.2).
bp55_in 1.50 0.10 {r_target[*] r_push_addr[*]}
# u_valid / u_fire, u_taken: training strobe and outcome come from the same EX branch
# resolution as the redirect controls (v2: u_fire = valid & ~stall of EX).
bp55_in 2.00 0.10 {u_valid u_fire u_taken}
# u_pc, u_type, u_isbr, u_meta: fields of the ID/EX (EX) pipeline register: clock-to-Q
# (0.4) + wire and the stall hold mux (0.4).
bp55_in 0.80 0.10 {u_pc[*] u_type[*] u_isbr u_meta[*]}
# u_target: EX target adder output, as r_target.
bp55_in 1.50 0.10 {u_target[*]}
# rst_n: released by a reset synchroniser flop in the core: clock-to-Q (0.4) + wire (0.2).
# It is timed (recovery/removal on the asynchronous-reset flops), not false-pathed: the
# release of an 8132-flop reset net has to meet recovery inside this block.
bp55_in 0.60 0.10 {rst_n}

# ---- outputs ------------------------------------------------------------------------
# f_taken: select of the 30-bit next-PC mux: select fanout buffer (0.3) + mux (0.2) +
# PC flop setup (0.15) + wire (0.15).
bp55_out 0.80 0.0 {f_taken}
# f_target: data leg of the same mux: mux (0.2) + PC flop setup (0.15) + wire (0.15).
bp55_out 0.50 0.0 {f_target[*]}
# f_hit, f_type, f_dir, f_ras_top, f_meta, f_ckpt: captured by the IF1/IF2 pipeline
# register and used by ID or carried to EX: flop setup (0.15) + wire (0.2).
# f_busy (v2): status to the core's fetch control, captured by a core flop; same budget.
bp55_out 0.35 0.0 {f_hit f_type[*] f_dir f_ras_top[*] f_meta[*] f_ckpt[*] f_busy}

# ---- electrical ---------------------------------------------------------------------
# Inputs driven by a mid-size buffer of the core; outputs see one buffer or flop input
# plus roughly 50 um of wire.
set bp55_data_in {}
foreach p [all_inputs] { if {[get_full_name $p] ne "clk"} { lappend bp55_data_in $p } }
set_driving_cell -lib_cell BUFX4H7R -pin Y $bp55_data_in
set_load 0.010 [all_outputs]
