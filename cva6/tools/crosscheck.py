#!/usr/bin/env python3
"""Consistency checks of the CVA6 results.

  crosscheck.py <results dir> <iss counts.csv>

Per variant and program:
  1. instret == iss/rvsim instruction count of the ISS twin (bench/build_cva6.sh)
  2. committed control-flow instructions (cond + jal + jalr) == rvsim "branches"
  3. hw_minstret == instret and hw_mcycle == cycles (csr_regfile's own counters)
  4. branch-unit resolutions == committed control-flow instructions, or + 1
     when the final `j .` resolves before the exit store commits (so there is
     no wrong-path resolution), mp_other == 0, res_nocf == 0, exceptions == 0
  5. instret and the committed control-flow counts are identical across variants
     (they depend on the program only)
Then a least-squares fit over all programs and variant pairs:
  d(cycles) = P_mp * d(mispredicts) + P_fe * d(frontend taken redirects)
which estimates the whole-program cost of one EX misprediction and of one
correctly predicted taken redirect, independently of the per-event probe.
Writes <results dir>/crosscheck.txt.
"""
import csv
import glob
import os
import sys


def main():
    resdir, counts = sys.argv[1:3]
    iss = {r["program"]: r for r in csv.DictReader(open(counts))}
    out, bad = [], 0
    data = {}
    for v in sorted(os.listdir(resdir)):
        for f in sorted(glob.glob(f"{resdir}/{v}/*.csv")):
            r = next(csv.DictReader(open(f)))
            data.setdefault(v, {})[r["program"]] = r
    for v, rows in data.items():
        fails = []
        for p, r in sorted(rows.items()):
            n = lambda k: int(r[k])
            cf = n("cond") + n("jal") + n("jal_call") + n("jalr_ret") + n("jalr_call") + n("jalr_ind")
            chk = []
            if p in iss:
                if n("instret") != int(iss[p]["instr"]):
                    chk.append(f"instret {n('instret')} != rvsim {iss[p]['instr']}")
                if cf != int(iss[p]["branches"]):
                    chk.append(f"control flow {cf} != rvsim {iss[p]['branches']}")
            else:
                chk.append("no rvsim count")
            if n("hw_minstret") != n("instret"):
                chk.append(f"hw_minstret {n('hw_minstret')} != {n('instret')}")
            if n("hw_mcycle") != n("cycles"):
                chk.append(f"hw_mcycle {n('hw_mcycle')} != cycles {n('cycles')}")
            # +0 or +1: the `j .` after the exit store may resolve before the store commits
            if n("res") - cf not in (0, 1):
                chk.append(f"resolutions {n('res')} != committed control flow {cf} (+1)")
            for k in ("mp_other", "res_nocf", "exceptions", "oob", "axi_err"):
                if n(k):
                    chk.append(f"{k}={n(k)}")
            if r["status"] != "pass":
                chk.append("status " + r["status"])
            if chk:
                fails.append(f"  {p}: " + "; ".join(chk))
        out.append(f"{v}: {len(rows)} programs, {len(rows) - len(fails)} pass every check")
        out += fails
        bad += len(fails)
    vs = list(data)
    for a in vs[1:]:
        for p in sorted(set(data[vs[0]]) & set(data[a])):
            for k in ("instret", "cond", "jal", "jal_call", "jalr_ret", "jalr_call", "jalr_ind"):
                if data[vs[0]][p][k] != data[a][p][k]:
                    out.append(f"  {p}: {k} differs between {vs[0]} and {a}")
                    bad += 1
    # least squares d(cycles) = P_mp d(mp) + P_fe d(fe), over the variants of the
    # default base (names without "-"), with all programs and without nsichneu,
    # whose misprediction cost is dominated by I$ misses on the redirect target
    fe = lambda r: sum(int(r[k]) for k in ("fe_taken_cond", "fe_taken_jal", "fe_taken_ret", "fe_taken_ind"))
    fvs = [v for v in vs if "-" not in v]
    for excl in (set(), {"nsichneu"}):
        pts = []
        for i, a in enumerate(fvs):
            for b in fvs[i + 1:]:
                for p in sorted((set(data[a]) & set(data[b])) - excl):
                    ra, rb = data[a][p], data[b][p]
                    pts.append((int(ra["cycles"]) - int(rb["cycles"]), int(ra["mp"]) - int(rb["mp"]), fe(ra) - fe(rb)))
        if len(pts) < 3:
            continue
        sxx = sum(x * x for _, x, _ in pts); syy = sum(y * y for _, _, y in pts); sxy = sum(x * y for _, x, y in pts)
        sx = sum(d * x for d, x, _ in pts); sy = sum(d * y for d, _, y in pts)
        det = sxx * syy - sxy * sxy
        if not det:
            continue
        pm = (sx * syy - sy * sxy) / det
        pf = (sy * sxx - sx * sxy) / det
        res = [d - pm * x - pf * y for d, x, y in pts]
        rel = sum(abs(e) for e in res) / max(1, sum(abs(d) for d, _, _ in pts))
        out.append(f"fit over {len(pts)} (program, variant pair) points{' without ' + ', '.join(sorted(excl)) if excl else ''}: "
                   f"cycles per EX mispredict {pm:.3f}, per frontend taken redirect {pf:.3f}; "
                   f"sum |residual| / sum |delta cycles| = {100 * rel:.1f} %")
    out.append("crosscheck: " + ("PASS" if bad == 0 else f"{bad} problems"))
    txt = "\n".join(out)
    print(txt)
    open(f"{resdir}/crosscheck.txt", "w").write(txt + "\n")
    sys.exit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()
