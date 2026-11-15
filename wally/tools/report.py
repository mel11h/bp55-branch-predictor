#!/usr/bin/env python3
"""Results table of the Wally harness.

usage: report.py <results dir> [cfg ...]

Reads <results>/<cfg>/<prog>.csv (one row per run) and writes <results>/summary.txt
(also printed): per program and per suite, CPI, redirects per 1000 instructions
(hpm6 "BP wrong": every E redirect, i.e. direction, target, return and class
errors), direction mispredictions per 1000 instructions (hpm7), and the measured
misprediction penalty.

Suite aggregation, both given: "mean" is the unweighted mean of the per-program
values (what the project has reported so far); "pooled" sums numerators and
denominators over the programs first (each instruction weighs the same).

Penalty: for a predictor configuration X against nobp on the same program,
(cycles_nobp - cycles_X) / (redirects_nobp - redirects_X): the cycles saved per
redirect avoided. "adj" first removes I$ and D$ stall cycles, which wrong-path
fetches can change, from both cycle counts. static is left out of the penalty
because its 1-cycle Decode redirects are not counted in hpm6.
"""
import csv
import sys
from pathlib import Path

ORDER = ["nobp", "static", "gshare", "gshare_iso", "twobit_iso", "local_iso", "bp55",
         "gshare_fix", "gshare_iso_fix", "gshare_iso_tag"]
SUITES = {"CoreMark": ["coremark"], "custom": ["interp", "recurse"]}


def load(res, cfgs):
    runs = {}
    for f in sorted(res.glob("*/*.csv")):
        r = next(csv.DictReader(open(f)))
        if cfgs and r["config"] not in cfgs:
            continue
        runs.setdefault(r["config"], {})[r["program"]] = r
    return runs


def main():
    res = Path(sys.argv[1])
    cfgs = sys.argv[2:]
    runs = load(res, cfgs)
    cfgs = [c for c in ORDER if c in runs] + sorted(c for c in runs if c not in ORDER)
    progs = sorted({p for c in cfgs for p in runs[c]})
    emb = [p for p in progs if p not in SUITES["CoreMark"] + SUITES["custom"]]
    suites = [("CoreMark", SUITES["CoreMark"]), (f"Embench ({len(emb)})", emb),
              ("custom (2)", SUITES["custom"]), (f"all ({len(progs)})", progs)]
    L = []
    pr = L.append
    # storage bits of each configuration (wally/tools/bitcount.py on the derived config.vh)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import bitcount
    cvw = res.resolve().parents[1] / "cores" / "cvw"
    tbits, pbits = {}, {}
    for c in cfgs:
        vh = cvw / "config" / "deriv" / f"rv32im_{c}" / "config.vh"
        if vh.exists():
            _, t, pp = bitcount.count(bitcount.params(vh.read_text()))
            tbits[c], pbits[c] = sum(t.values()), sum(pp.values())

    def val(c, p, num, den="instret", scale=1.0):
        r = runs[c].get(p)
        if r is None or r["status"] != "pass":
            return None
        return scale * float(num(r) if callable(num) else r[num]) / float(r[den])

    def table(title, num, scale, fmt):
        pr(f"\n{title}")
        pr(f"{'program':<16}" + "".join(f"{c:>15}" for c in cfgs))
        pr(f"{'  table bits':<16}" + "".join(f"{tbits.get(c, '?'):>15}" for c in cfgs))
        for p in progs:
            cells = []
            for c in cfgs:
                v = val(c, p, num, scale=scale)
                cells.append(f"{'-' if v is None else fmt % v:>15}")
            pr(f"{p:<16}" + "".join(cells))
        for name, ps in suites:
            for kind in ("mean", "pooled"):
                cells = []
                for c in cfgs:
                    vs = [val(c, p, num, scale=scale) for p in ps]
                    if any(v is None for v in vs):
                        cells.append(f"{'-':>15}"); continue
                    if kind == "mean":
                        v = sum(vs) / len(vs)
                    else:
                        n = sum(float(num(runs[c][p]) if callable(num) else runs[c][p][num]) for p in ps)
                        d = sum(float(runs[c][p]["instret"]) for p in ps)
                        v = scale * n / d
                    cells.append(f"{fmt % v:>15}")
                pr(f"{(name + ' ' + kind):<16}" + "".join(cells))

    fail = [(c, p) for c in cfgs for p in runs[c] if runs[c][p]["status"] != "pass"]
    pr("Wally rv32im (rv32gc without C), BP55 harness. hpm-style counters from reset to the tohost store.")
    pr(f"runs: {sum(len(runs[c]) for c in cfgs)}, failed: {len(fail)} {fail if fail else ''}")
    table("CPI (cycles / instructions retired)", "cycles", 1.0, "%.4f")
    table("Redirects per 1000 instructions (hpm6, all E redirects)", "bpwrong", 1000.0, "%.2f")
    table("Direction mispredictions per 1000 instructions (hpm7)", "dirwrong", 1000.0, "%.2f")
    table("Target mispredictions per 1000 instructions (hpm8, BTB target of taken branch/jump)", "tgtwrong", 1000.0, "%.2f")
    table("Return mispredictions per 1000 instructions (hpm9)", "raswrong", 1000.0, "%.2f")
    table("Class mispredictions per 1000 instructions (hpm10)", "classwrong", 1000.0, "%.2f")

    if "bp55" in runs:
        table("BP55 repair-only redirects per 1000 instructions (next PC right, speculative history/stack wrong)",
              lambda r: r.get("bp55_repair_only") or 0, 1000.0, "%.3f")
    pr("\nStorage: table bits (comparable to BP55's 8523) and pipeline bits (per-instruction prediction state "
       "carried D/E/M inside src/ifu/bpred, not in the table bits)")
    for c in cfgs:
        if c in tbits:
            pr(f"  {c:<12} table {tbits[c]:6d}  pipeline {pbits[c]:4d}  total {tbits[c] + pbits[c]:6d}")

    # penalty
    pcfgs = [c for c in cfgs if c not in ("nobp", "static")]
    if "nobp" in runs and pcfgs:
        pr("\nMeasured redirect penalty (cycles per redirect avoided, vs nobp): raw / adj (I$+D$ stall cycles removed)")
        pr(f"{'program':<16}" + "".join(f"{c:>18}" for c in pcfgs))
        tot = {c: [0, 0, 0] for c in pcfgs}
        for p in progs:
            b = runs["nobp"].get(p)
            cells = []
            for c in pcfgs:
                x = runs[c].get(p)
                if not b or not x or b["status"] != "pass" or x["status"] != "pass":
                    cells.append(f"{'-':>18}"); continue
                dc = int(b["cycles"]) - int(x["cycles"])
                st = lambda r: int(r["icache_stall"]) + int(r["dcache_stall"])
                da = dc - (st(b) - st(x))
                dr = int(b["bpwrong"]) - int(x["bpwrong"])
                tot[c][0] += dc; tot[c][1] += da; tot[c][2] += dr
                cells.append(f"{dc / dr:8.3f} / {da / dr:7.3f}" if dr else f"{'-':>18}")
            pr(f"{p:<16}" + "".join(cells))
        pr(f"{'pooled':<16}" + "".join(f"{tot[c][0] / tot[c][2]:8.3f} / {tot[c][1] / tot[c][2]:7.3f}" for c in pcfgs))

    # speed
    cyc = sum(int(r["cycles"]) for c in cfgs for r in runs[c].values())
    wall = sum(float(r["wall_s"]) for c in cfgs for r in runs[c].values())
    pr(f"\nsimulation: {cyc / 1e6:.0f} M cycles in {wall / 3600:.2f} process-hours, "
       f"{cyc / wall / 1e3:.0f} k cycles/s per process (machine shared with other jobs)")
    notes = [(c, p, runs[c][p]["notes"]) for c in cfgs for p in progs if p in runs[c] and runs[c][p]["notes"]]
    for c, p, n in notes:
        pr(f"note {c} {p}: {n}")
    text = "\n".join(L) + "\n"
    (res / "summary.txt").write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
