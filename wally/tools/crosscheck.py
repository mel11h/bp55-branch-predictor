#!/usr/bin/env python3
"""Honesty checks of the Wally harness (wally/wally.sh crosscheck).

usage: crosscheck.py <repo root> [<results dir> <bench dir> <twin extra>]

<twin extra> is rvsim's count minus Wally's instret by construction (0; 1 for the RELAX=1
build, whose twin starts with a jump at address 0). Configurations with the RAS_HINT_FIX
option (wally/patches/0003) count a jalr with rd = rs1 = x1/x5 as a call, not a return.

1. Instructions: Wally's instret (every configuration in wally/results) against
   iss/rvsim's instruction count of the program's ISS twin (bench/build/wally/iss,
   same objects, linked at 0, I/O routines of equal length): must be equal.
   Also lists the offset to the traced binaries of bench/build.sh (bench/build).
2. Control flow: the ISS twin's control-flow trace (rvsim, streamed, not stored)
   against Wally's class counters, and for nobp the redirect count, which must be
   taken conditional branches + all jumps (Wally without a predictor fetches
   PC+4 and redirects from E on PCSrcE).
Writes wally/results/crosscheck.csv and prints a table.
"""
import csv
import subprocess
import sys
from pathlib import Path

import numpy as np

REC = np.dtype([("pc", "<u4"), ("target", "<u4"), ("gap", "<u2"), ("type", "u1"), ("taken", "u1")])
T_COND, T_JUMP, T_CALL, T_RET, T_IND, T_ICALL = range(6)


def rvsim(root, binf, trace):
    p = subprocess.run([str(root / "iss/rvsim"), str(binf), "/dev/stdout" if trace else "/dev/null", "100000000"],
                       capture_output=True)
    last = p.stderr.decode(errors="replace").strip().splitlines()[-1]
    kv = dict(f.split("=") for f in last.split()[1:])
    return int(kv["instr"]), (np.frombuffer(p.stdout, REC) if trace else None)


def main():
    root = Path(sys.argv[1])
    res = Path(sys.argv[2]) if len(sys.argv) > 2 else root / "wally/results"
    bw = Path(sys.argv[3]) if len(sys.argv) > 3 else root / "bench/build/wally"
    extra = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    cfgdir = root / "wally/configs"
    fixcfg = {c.stem for c in cfgdir.glob("*.cfg") if "RAS_HINT_FIX" in c.read_text()}
    runs = {}
    for f in sorted(res.glob("*/*.csv")):
        r = next(csv.DictReader(open(f)))
        runs.setdefault(r["program"], {})[r["config"]] = r
    out = []
    print(f"{'program':<15} {'iss twin':>9} {'wally':>9} {'d':>2} {'traced':>9} {'twin-tr':>7} | "
          f"{'cond':>8} {'tkn':>8} {'jal':>7} {'jalr':>7} {'ret(rv)':>7} | hpm3/4/5 match | nobp redirects: wally trace d")
    allok = True
    for prog in sorted(runs):
        twin, tr = rvsim(root, bw / "iss" / f"{prog}.bin", True)
        traced, _ = rvsim(root, root / "bench/build" / f"{prog}.bin", False)
        ty, tk = tr["type"], tr["taken"]
        cond = int((ty == T_COND).sum()); taken = int(((ty == T_COND) & (tk == 1)).sum())
        jal = int(((ty == T_JUMP) | (ty == T_CALL)).sum())
        jalr = int(((ty == T_RET) | (ty == T_IND) | (ty == T_ICALL)).sum())
        ret_rv = int((ty == T_RET).sum())
        # Wally's ReturnD: any jalr whose rs1 is x1 or x5 (rd not checked), see icpred.sv.
        # rvsim calls jalr with a link rd an ICALL first, so "jalr ra, 0(ra)" is ICALL there and a
        # return (and a call) in Wally. Recover rs1 from the instruction word of the ISS image.
        img = np.fromfile(bw / "iss" / f"{prog}.bin", dtype="<u4")
        jr = tr[(ty == T_RET) | (ty == T_IND) | (ty == T_ICALL)]
        words = img[jr["pc"] // 4]
        rs1 = (words >> 15) & 31
        ret_w = int(((rs1 == 1) | (rs1 == 5)).sum())
        rd = (words >> 7) & 31
        # "jalr ra, imm(ra)": the second half of every direct call, because the programs are
        # built with -mno-relax (call = auipc ra + jalr ra). Wally decodes it as call AND return.
        callret = int((((rs1 == 1) | (rs1 == 5)) & ((rd == 1) | (rd == 5))).sum())
        insts = {c: int(r["instret"]) for c, r in runs[prog].items()}
        ok_i = all(v == twin - extra for v in insts.values())
        ok_c = True
        for c, rr in runs[prog].items():
            b, j, rt = int(rr["branches"]), int(rr["jumps"]), int(rr["returns"])
            er = ret_w - callret if c in fixcfg else ret_w
            ok_c &= b == cond and rt == er and j == jal - extra + jalr - er   # the twin's start-up jump
        any_r = runs[prog].get("gshare") or next(iter(runs[prog].values()))
        b, j, rt = int(any_r["branches"]), int(any_r["jumps"]), int(any_r["returns"])
        nobp = runs[prog].get("nobp")
        exp = taken + jal + jalr
        nb = int(nobp["bpwrong"]) if nobp else None
        ok_n = nobp is None or nb == exp
        allok &= ok_i and ok_c and ok_n
        print(f"{prog:<15} {twin:9d} {min(insts.values()):9d} {max(insts.values()) - twin + extra:2d} {traced:9d} {twin - traced:7d} | "
              f"{cond:8d} {taken:8d} {jal:7d} {jalr:7d} {ret_rv:7d} | {'yes' if ok_c else 'NO'} (ret wally-def {ret_w}, jalr ra,ra {callret})"
              f" | {nb} {exp} {'' if nb is None else nb - exp}")
        out.append(dict(program=prog, iss_twin_instr=twin, wally_instret_min=min(insts.values()),
                        wally_instret_max=max(insts.values()), configs=len(insts), traced_instr=traced,
                        twin_minus_traced=twin - traced, cond=cond, cond_taken=taken, jal=jal, jalr=jalr,
                        ret_rvsim=ret_rv, ret_wally_def=ret_w, jalr_link_link=callret, hpm_branches=b, hpm_jumps=j, hpm_returns=rt,
                        nobp_bpwrong=nb, nobp_expected=exp, instr_ok=ok_i, class_ok=ok_c, nobp_ok=ok_n))
    with open(res / "crosscheck.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0]))
        w.writeheader(); w.writerows(out)
    print("ALL CHECKS PASS" if allok else "SOME CHECKS FAIL")
    sys.exit(0 if allok else 1)


if __name__ == "__main__":
    main()
