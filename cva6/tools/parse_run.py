#!/usr/bin/env python3
"""Turn one CVA6 simulation log into a one-row CSV (stdout).

usage: parse_run.py <variant> <prog> <log> <console> <iss console> <wall s> <mem_lat> "<columns>"

status is "pass" when the program stored exit code 0 to tohost (testbench
status PASS) and its console output on CVA6 is byte-identical to the console
output of its ISS twin on iss/rvsim; for CoreMark the CRCs must also be the
reference values of the 2K performance run (seeds 0, 0, 0x66) and no CRC error
may be reported (the "Must execute for at least 10 secs" error is expected:
there is no timer). Exit status 1 when the log has no BP55CVA6 line.
"""
import re
import sys

REF_COREMARK = {"seedcrc": "0xe9f5", "[0]crclist": "0xe714", "[0]crcmatrix": "0x1fd7",
                "[0]crcstate": "0x8e3a", "[0]crcfinal": "0xa14c"}


def main():
    var, prog, logf, conf, issf, wall, mem_lat, cols = sys.argv[1:9]
    # the wrong-path probe and the raw cycle count of the whole simulation
    cols = cols.split() + [c for c in ("wp_found", "wp_instr_hist", "wp_rasop_hist", "sim_cycles")
                           if c not in cols.split()]
    log = open(logf, errors="replace").read()
    m = re.search(r"^BP55CVA6 (.*)$", log, re.M)
    if not m:
        print("variant,program,status\n%s,%s,nolog" % (var, prog))
        sys.exit(1)
    kv = dict(f.split("=", 1) for f in m.group(1).split())
    rss = re.search(r"MAXRSS_KB=(\d+)", log)
    console = open(conf, errors="replace").read()
    iss = open(issf, errors="replace").read()
    notes = []
    ok = kv["status"] == "PASS"
    if not ok:
        notes.append("testbench " + kv["status"] + " exit_value=" + kv["exit_value"])
    if console != iss:
        ok = False
        notes.append("console differs from ISS twin")
    if prog == "coremark":
        for k, v in REF_COREMARK.items():
            mm = re.search(re.escape(k) + r"\s*:\s*(0x[0-9a-f]+)", console)
            if not mm or mm.group(1) != v:
                ok = False
                notes.append(f"{k} {mm.group(1) if mm else 'missing'} != {v}")
        if re.search(r"ERROR! (list|matrix|state) crc", console) or "2K performance run parameters" not in console:
            ok = False
            notes.append("coremark self-check failed")
    for k in ("exceptions", "mp_other", "res_nocf", "oob", "axi_err"):
        if kv.get(k, "0") != "0":
            notes.append(f"{k}={kv[k]}")
    hdr = ["variant", "program", "status"] + cols + ["mem_lat", "wall_s", "maxrss_kb", "notes"]
    row = [var, prog, "pass" if ok else "FAIL"] + [kv.get(c, "") for c in cols] + \
          [mem_lat, "%.1f" % float(wall), rss.group(1) if rss else "", "; ".join(notes)]
    print(",".join(hdr))
    print(",".join(row))


if __name__ == "__main__":
    main()
