#!/usr/bin/env python3
"""Results table of the CVA6 harness.

  report.py <results dir> [variant ...]

For every variant (default: every results/<variant>/ directory that has CSVs)
prints one row per program and two suite rows, and writes the whole text to
<results dir>/summary.txt and the suite rows to <results dir>/suite.csv:
  mean    unweighted mean over the programs of the per-program figure
  pooled  the figure of all programs taken together (sum of cycles over sum of
          instructions, sum of mispredictions over sum of instructions, ...)
Columns:
  CPI       cycles / instret (whole program, reset to exit store)
  MPKI      EX mispredictions (resolved_branch.is_mispredict) per 1000 instructions
  dir/ret/ind  the same split by cause: conditional-branch direction, return
            (RAS empty or wrong), other indirect jump (BTB empty or wrong)
  FEtk      frontend predicted-taken redirects (branch, JAL, return, JALR) per
            1000 instructions; each costs a fetch bubble even when correct
  The wrong-path lines sum the per-mispredict histograms of the probe in
  bp55_cva6_main.cpp (bin i = i younger instructions / RAS operations; the
  last bin, 16, means 16 or more).
  pen       misprediction penalty in cycles: the mode, over mispredicted
            resolutions, of (cycles from the issue of the mispredicted
            instruction to the issue of the next correct-path instruction),
            minus 1, the gap of back-to-back issue; penM is the same from the
            mean (includes stalls, e.g. an I$ miss on the redirect target)
  okM       the same mean gap minus 1 over correctly predicted resolutions
            (includes the one-cycle fetch bubble of every predicted-taken
            redirect and ordinary stalls)
"""
import csv
import glob
import os
import sys

PROG_ORDER = ["coremark", "aha-mont64", "crc32", "depthconv", "edn", "huffbench", "matmult-int", "md5sum",
              "nettle-aes", "nettle-sha256", "nsichneu", "picojpeg", "qrduino", "sglib-combined", "slre",
              "statemate", "tarfind", "ud", "xgboost", "interp", "recurse"]


def load(resdir, var):
    rows = {}
    for f in glob.glob(f"{resdir}/{var}/*.csv"):
        r = next(csv.DictReader(open(f)))
        rows[r["program"]] = r
    return rows


def figs(r):
    i = int(r["instret"])
    k = 1000.0 / i
    fe = sum(int(r[x]) for x in ("fe_taken_cond", "fe_taken_jal", "fe_taken_ret", "fe_taken_ind"))
    return {
        "CPI": int(r["cycles"]) / i,
        "MPKI": int(r["mp"]) * k,
        "dir": int(r["mp_dir"]) * k,
        "ret": (int(r["mp_ret_nopred"]) + int(r["mp_ret_wrong"])) * k,
        "ind": (int(r["mp_ind_nopred"]) + int(r["mp_ind_wrong"])) * k,
        "FEtk": fe * k,
        "pen": int(r["pen_mode_mp"]) - 1 if int(r["pen_n_mp"]) else float("nan"),
        "penM": float(r["pen_mean_mp"]) - 1 if int(r["pen_n_mp"]) else float("nan"),
        "okM": float(r["pen_mean_ok"]) - 1,
    }


COLS = ["CPI", "MPKI", "dir", "ret", "ind", "FEtk", "pen", "penM", "okM"]
FMT = {"CPI": "{:7.4f}", "MPKI": "{:7.2f}", "dir": "{:6.2f}", "ret": "{:6.2f}", "ind": "{:6.2f}",
       "FEtk": "{:6.1f}", "pen": "{:4.0f}", "penM": "{:5.2f}", "okM": "{:5.2f}"}


def line(name, status, f):
    return f"{name:<15} {status:<5} " + " ".join(FMT[c].format(f[c]) for c in COLS)


def main():
    resdir = sys.argv[1]
    variants = sys.argv[2:] or sorted(d for d in os.listdir(resdir)
                                      if os.path.isdir(f"{resdir}/{d}") and glob.glob(f"{resdir}/{d}/*.csv"))
    out = []
    suite_rows = []
    for v in variants:
        rows = load(resdir, v)
        if not rows:
            continue
        progs = [p for p in PROG_ORDER if p in rows] + sorted(set(rows) - set(PROG_ORDER))
        out.append(f"== {v}  ({len(progs)} programs, mem_lat {rows[progs[0]]['mem_lat']})")
        out.append(f"{'program':<15} {'stat':<5} " + " ".join(
            c.rjust(len(FMT[c].format(0.0))) for c in COLS))
        per = {}
        for p in progs:
            per[p] = figs(rows[p])
            note = rows[p].get("notes", "")
            out.append(line(p, rows[p]["status"], per[p]) + (f"   [{note}]" if note else ""))
        npass = sum(rows[p]["status"] == "pass" for p in progs)
        mean = {c: sum(per[p][c] for p in progs) / len(progs) for c in COLS}
        tot = {k: sum(int(rows[p][k]) for p in progs) for k in
               ("cycles", "instret", "mp", "mp_dir", "mp_ret_nopred", "mp_ret_wrong", "mp_ind_nopred",
                "mp_ind_wrong", "fe_taken_cond", "fe_taken_jal", "fe_taken_ret", "fe_taken_ind",
                "pen_n_mp", "pen_n_ok")}
        k = 1000.0 / tot["instret"]
        pm = sum(float(rows[p]["pen_mean_mp"]) * int(rows[p]["pen_n_mp"]) for p in progs) / max(1, tot["pen_n_mp"])
        po = sum(float(rows[p]["pen_mean_ok"]) * int(rows[p]["pen_n_ok"]) for p in progs) / max(1, tot["pen_n_ok"])
        modes = sorted(set(per[p]["pen"] for p in progs if per[p]["pen"] == per[p]["pen"]))
        pooled = {"CPI": tot["cycles"] / tot["instret"], "MPKI": tot["mp"] * k, "dir": tot["mp_dir"] * k,
                  "ret": (tot["mp_ret_nopred"] + tot["mp_ret_wrong"]) * k,
                  "ind": (tot["mp_ind_nopred"] + tot["mp_ind_wrong"]) * k,
                  "FEtk": sum(tot[x] for x in ("fe_taken_cond", "fe_taken_jal", "fe_taken_ret", "fe_taken_ind")) * k,
                  "pen": modes[0] if len(modes) == 1 else float("nan"), "penM": pm - 1, "okM": po - 1}
        out.append(line("mean", f"{npass}/{len(progs)}", mean))
        out.append(line("pooled", "", pooled) + (f"   [per-program pen modes {modes}]" if len(modes) != 1 else ""))
        # wrong-path probe, summed over the programs
        for key, what in (("wp_instr_hist", "younger instructions in the queue"),
                          ("wp_rasop_hist", "wrong-path RAS push/pop operations")):
            h = []
            for p in progs:
                for i, x in enumerate(int(v) for v in rows[p].get(key, "").split(":") if v):
                    h += [0] * (i + 1 - len(h))
                    h[i] += x
            n = sum(h)
            if n:
                over2 = sum(h[3:]) / n
                out.append(f"per EX mispredict, {what}: histogram {':'.join(map(str, h))} "
                           f"(max {len(h) - 1}{'+' if len(h) == 17 else ''}, more than 2 in {100 * over2:.3f} %)")
        out.append("")
        for name, f in (("mean", mean), ("pooled", pooled)):
            suite_rows.append([v, name, len(progs), npass] + ["%.6g" % f[c] for c in COLS])
    txt = "\n".join(out)
    print(txt)
    open(f"{resdir}/summary.txt", "w").write(txt + "\n")
    with open(f"{resdir}/suite.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["variant", "aggregate", "programs", "pass"] + COLS)
        w.writerows(suite_rows)


if __name__ == "__main__":
    main()
