#!/usr/bin/env python3
"""Turn one Wally simulation log into a one-row CSV (stdout).

usage: parse_run.py <cfg> <prog> <log> <iss console file> <wall seconds> "<columns>"

status is "pass" when the testbench saw tohost = 1 (exit code 0) and the
program's console output on Wally is byte-identical to the console output of
its ISS twin on iss/rvsim; for CoreMark the CRCs must also be the reference
values of the 2K performance run (seeds 0, 0, 0x66) and no CRC error may be
reported. Exit status 1 when the log has no BP55PERF line.
"""
import re
import sys

REF_COREMARK = {"seedcrc": "0xe9f5", "[0]crclist": "0xe714", "[0]crcmatrix": "0x1fd7", "[0]crcstate": "0x8e3a"}


def console_of(log):
    # The HTIF console characters are $write-n by the testbench between its own
    # lines; everything before "<elf> succeeded"/"Error on test"/"BP55PERF" that is
    # not a testbench message is program output.
    out = []
    lines = log.splitlines(keepends=True)
    if lines and re.match(r"Running \d+ tests? ?$", lines[0].rstrip("\n")):
        lines = lines[1:]
    for line in lines:
        if line.startswith(("BP55PERF", "- ")) or "succeeded.  Brilliant" in line or "Error on test" in line:
            break
        out.append(line)
    return "".join(out)


def main():
    cfg, prog, logf, issf, wall, cols = sys.argv[1:7]
    cols = cols.split()
    log = open(logf, errors="replace").read()
    m = re.search(r"^BP55PERF (.*)$", log, re.M)
    if not m:
        print("config,program,status\n%s,%s,nolog" % (cfg, prog))
        sys.exit(1)
    kv = dict(f.split("=", 1) for f in m.group(1).split())
    console = console_of(log[: m.start()])
    iss = open(issf, errors="replace").read()
    notes = []
    ok = kv["tohost"] == "1" and kv["done"] == "1"
    if not ok:
        notes.append("tohost=" + kv["tohost"])
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
        mm = re.search(r"\[0\]crcfinal\s*:\s*(0x[0-9a-f]+)", console)
        notes.append("crcfinal " + (mm.group(1) if mm else "missing"))
    if kv["hw_mcycle"] != kv["cycles"]:
        notes.append(f"hw_mcycle {kv['hw_mcycle']} != cycles")
    hdr = ["config", "program", "status"] + cols + ["wall_s", "notes"]
    row = [cfg, prog, "pass" if ok else "FAIL"] + [kv.get(c, "") for c in cols] + [wall, "; ".join(notes)]
    print(",".join(hdr))
    print(",".join(row))


if __name__ == "__main__":
    main()
