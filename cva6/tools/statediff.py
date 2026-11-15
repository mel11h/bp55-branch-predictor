#!/usr/bin/env python3
"""Extra per-instruction pipeline state of a variant against a reference build.

  statediff.py <build dir A> <build dir B>

Reads members.txt.gz (cva6/tools/bitcount.py --dump, written by every build)
of both Verilated models and prints the registers whose width differs, plus
BP55 registers that exist only in A, excluding A's BP55 tables (counted by
bitcount.py). A member is taken to be state when its name is a CVA6 register
(*_q, FIFO / scoreboard mem_q, ID's issue_q, the issue stage's registered
branch_predict_o) or one of the frontend's bp55_*_q / bp55_ph_pend registers;
combinational members that also widen are counted separately, not summed.
"""
import gzip
import re
import sys


def load(d):
    m = {}
    for ln in gzip.open(d + "/members.txt.gz", "rt"):
        w, n = ln.split()
        m[n] = int(w)
    return m


STATE = re.compile(r"(_q|mem_q|_q__BRA__\d+__KET____DOT__sbe|branch_predict_o__DOT__bp55|bp55_ph_pend)$")


def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    state, comb = [], []
    for n, w in sorted(a.items()):
        if "__DOT__i_bp55__DOT__" in n:
            continue
        if n not in b and "bp55" not in n:
            continue      # Verilator-internal or optimisation-dependent names
        d = w - b.get(n, 0)
        if d <= 0:
            continue
        short = n.replace("bp55_cva6_tb__DOT__i_cva6__DOT__", "")
        (state if STATE.search(n) else comb).append((d, w, short))
    tot = sum(d for d, _, _ in state)
    print("state registers (extra bits, width in A):")
    for d, w, n in state:
        print(f"  {d:6d} {w:7d}  {n}")
    print(f"total extra state: {tot} bits")
    print(f"(not counted: {len(comb)} combinational members wider in A, {sum(d for d, _, _ in comb)} bits)")


if __name__ == "__main__":
    main()
