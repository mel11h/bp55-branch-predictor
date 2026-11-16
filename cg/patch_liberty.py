#!/usr/bin/env python3
"""Add the missing clock-gating description to the ICsprout55 H7CR ICG cells.

The upstream Liberty (release v1.10.103) marks the ten ICG cells (ICGX*H7R,
ICGNX*H7R) with clock_gating_integrated_cell, but:
  * declares them "latch_posedge_postcontrol" / "latch_negedge_postcontrol",
    a type that implies a test-control input (clock_gate_test_pin); the cells
    have no such pin (Verilog model, CDL and LEF have only CK|CKN, E, ECK);
  * has no clock_gate_clock_pin / clock_gate_enable_pin / clock_gate_out_pin;
  * has no internal state (statetable) and no function / state_function on
    ECK, so the cell's logic is not described at all.
The timing arcs (CK->ECK combinational, setup/hold of E against CK) and the
power tables are present and are left untouched.

What this script changes, per ICG cell, nothing else in the file:
  clock_gating_integrated_cell  latch_posedge  (ICGX)  / latch_negedge (ICGN)
  statetable ("CK E", "IQ")     latch transparent while CK is low (ICGX),
                                while CKN is high (ICGN), as in the Verilog
                                UDPs ipicg_latchnsr / ipicg_latchsr and the CDL
  pin IQ                        direction internal, internal_node IQ
  pin CK / CKN                  clock_gate_clock_pin : true
  pin E                         clock_gate_enable_pin : true
  pin ECK                       clock_gate_out_pin : true,
                                state_function "CK & IQ" (ICGX) / "CKN | !IQ" (ICGN)

usage: patch_liberty.py <upstream .lib> <patched .lib>
       patch_liberty.py --all <upstream liberty dir> <output dir>   (the three flow corners)
The input is never modified. A summary line per cell goes to stdout.
"""
import hashlib
import os
import re
import sys

CORNERS = [
    "ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm.lib",
    "ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib",
    "ics55_LLSC_H7CR_ff_rcbest_1p32_m40_nldm.lib",
]

ICG_RE = re.compile(r"^\s*cell\s*\(\s*\"?(ICGN?X\w+H7R)\"?\s*\)\s*\{")
CGIC_RE = re.compile(r"^(\s*)clock_gating_integrated_cell\s*:\s*\"([^\"]*)\"\s*;")
PIN_RE = re.compile(r"^(\s*)pin\s*\(\s*\"?(\w+)\"?\s*\)\s*\{")


def statetable(neg, ind):
    if neg:   # ICGN: latch transparent while CKN is high, holds while low
        rows = ["H L : - : L", "H H : - : H", "L - : - : N"]
        head = '"CKN E"'
    else:     # ICG: latch transparent while CK is low, holds while high
        rows = ["L L : - : L", "L H : - : H", "H - : - : N"]
        head = '"CK E"'
    body = (", \\\n" + ind + "          ").join(rows)
    return (f"{ind}statetable ({head}, \"IQ\") {{\n"
            f"{ind}  table : \"{body}\" ;\n"
            f"{ind}}}\n"
            f"{ind}pin (IQ) {{\n"
            f"{ind}  direction : internal ;\n"
            f"{ind}  internal_node : \"IQ\" ;\n"
            f"{ind}}}\n")


def patch(src, dst):
    out = []
    cell = None          # name of the ICG cell being patched
    depth = 0            # brace depth inside that cell (cell line = 1)
    seen = {}
    with open(src) as f:
        for line in f:
            if cell is None:
                m = ICG_RE.match(line)
                out.append(line)
                if m:
                    cell = m.group(1)
                    neg = cell.startswith("ICGN")
                    depth = line.count("{") - line.count("}")
                    seen[cell] = []
                continue
            m = CGIC_RE.match(line) if depth == 1 else None
            pm = PIN_RE.match(line) if depth == 1 else None
            if m:
                ind, old = m.group(1), m.group(2)
                new = "latch_negedge" if neg else "latch_posedge"
                out.append(f"{ind}clock_gating_integrated_cell : \"{new}\" ;\n")
                out.append(statetable(neg, ind))
                seen[cell].append(f"type {old}->{new}")
            elif pm:
                ind, pin = pm.group(1), pm.group(2)
                out.append(line)
                ind2 = ind + "  "
                if pin in ("CK", "CKN"):
                    out.append(f"{ind2}clock_gate_clock_pin : true ;\n")
                    seen[cell].append(f"{pin}:clock_gate_clock_pin")
                elif pin == "E":
                    out.append(f"{ind2}clock_gate_enable_pin : true ;\n")
                    seen[cell].append("E:clock_gate_enable_pin")
                elif pin == "ECK":
                    fn = "CKN | !IQ" if neg else "CK & IQ"
                    out.append(f"{ind2}clock_gate_out_pin : true ;\n")
                    out.append(f"{ind2}state_function : \"{fn}\" ;\n")
                    seen[cell].append(f"ECK:clock_gate_out_pin,state_function={fn}")
                else:
                    raise SystemExit(f"{src}: unexpected pin {pin} in {cell}")
            else:
                if depth == 1 and re.match(r"^\s*(statetable|clock_gate_|state_function)", line):
                    raise SystemExit(f"{src}: {cell} already has {line.strip()}; refusing to patch twice")
                out.append(line)
            depth += line.count("{") - line.count("}")
            if depth == 0:
                cell = None
    expected = 10 if "ss_cworst_1p08_m40" not in src else 9
    if len(seen) != expected:
        raise SystemExit(f"{src}: found {len(seen)} ICG cells, expected {expected}")
    for c, items in seen.items():
        if len(items) != 4:
            raise SystemExit(f"{src}: {c}: incomplete patch {items}")
    tmp = dst + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(out)
    os.replace(tmp, dst)
    return seen


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main(argv):
    if len(argv) == 4 and argv[1] == "--all":
        pairs = [(os.path.join(argv[2], c), os.path.join(argv[3], c)) for c in CORNERS]
        os.makedirs(argv[3], exist_ok=True)
    elif len(argv) == 3:
        pairs = [(argv[1], argv[2])]
    else:
        raise SystemExit(__doc__)
    for src, dst in pairs:
        if os.path.abspath(src) == os.path.abspath(dst):
            raise SystemExit("refusing to overwrite the input")
        seen = patch(src, dst)
        print(f"{os.path.basename(src)}: in sha256 {sha256(src)}")
        print(f"{os.path.basename(dst)}: out sha256 {sha256(dst)}")
        for c, items in seen.items():
            print(f"  {c}: {'; '.join(items)}")


if __name__ == "__main__":
    main(sys.argv)
