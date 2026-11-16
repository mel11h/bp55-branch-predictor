#!/usr/bin/env python3
"""Per-table ("coarse") clock-gating preparation on a Yosys JSON netlist.

usage: coarse_gate.py <in.json> <out.json> [min_flops]

Input: the design after "synth -flatten; opt -full" (generic $_DFFE_* cells). For every table
(flops grouped by the base name of the net on Q: btb_tag[12] -> btb_tag, bim[3] -> bim) with at
least min_flops (default 64) enable flops, each flop
      $_DFFE_PP_ (C, D, E=e_row, Q)
is rewritten to
      $_DFFE_PP_ (C, D'=e_row ? D : Q, E=e_table, Q),   e_table = OR of all e_row of the table
which is the same function (when e_table = 1 and e_row = 0 the flop reloads Q). A following
"clockgate -min_net_size 1" then puts one ICG per table on e_table, and the per-row enable stays
as the D-side multiplexer. $_DFFE_PN_ (active-low enable) is handled with an inverter; flops with
a reset or set are left alone.
Prints one line per table.
"""
import collections
import json
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
min_flops = int(sys.argv[3]) if len(sys.argv) > 3 else 64
d = json.load(open(src))
(mname, mod), = [(k, v) for k, v in d["modules"].items() if v.get("attributes", {}).get("top") or k == "bp55"]
cells, nets = mod["cells"], mod["netnames"]

maxbit = 1
for n in nets.values():
    for b in n["bits"]:
        if isinstance(b, int):
            maxbit = max(maxbit, b)
for c in cells.values():
    for bits in c["connections"].values():
        for b in bits:
            if isinstance(b, int):
                maxbit = max(maxbit, b)


def newbit():
    global maxbit
    maxbit += 1
    return maxbit


# bit -> public net name
bitname = {}
for name, n in nets.items():
    if n.get("hide_name"):
        continue
    for i, b in enumerate(n["bits"]):
        if isinstance(b, int) and b not in bitname:
            bitname[b] = name


def base(name):
    return re.sub(r"(\[\d+\])+$", "", name.lstrip("\\"))


groups = collections.defaultdict(list)
for cn, c in cells.items():
    if c["type"] in ("$_DFFE_PP_", "$_DFFE_PN_"):
        q = c["connections"]["Q"][0]
        if q in bitname:
            groups[base(bitname[q])].append(cn)

P = lambda v, w=32: format(v, "0%db" % w)
k = 0
for t, members in sorted(groups.items()):
    if len(members) < min_flops:
        continue
    rows = {}
    for cn in members:
        c = cells[cn]
        e = c["connections"]["E"][0]
        if c["type"] == "$_DFFE_PN_":
            key = ("n", e)
            if key not in rows:
                y = newbit()
                cells[f"$cg_coarse_not_{k}"] = {"hide_name": 1, "type": "$_NOT_", "parameters": {}, "attributes": {},
                    "port_directions": {"A": "input", "Y": "output"}, "connections": {"A": [e], "Y": [y]}}
                k += 1
                rows[key] = y
            erow = rows[key]
        else:
            rows.setdefault(("p", e), e)
            erow = e
        c["_erow"] = erow
    ens = sorted(set(rows.values()), key=str)
    etab = newbit()
    cells[f"$cg_coarse_or_{t}"] = {"hide_name": 1, "type": "$reduce_or",
        "parameters": {"A_SIGNED": P(0), "A_WIDTH": P(len(ens)), "Y_WIDTH": P(1)}, "attributes": {},
        "port_directions": {"A": "input", "Y": "output"}, "connections": {"A": ens, "Y": [etab]}}
    nets[f"cg_coarse_en_{t}"] = {"hide_name": 0, "bits": [etab], "attributes": {}}
    for cn in members:
        c = cells[cn]
        erow = c.pop("_erow")
        dnew = newbit()
        cells[f"$cg_coarse_mux_{k}"] = {"hide_name": 1, "type": "$_MUX_", "parameters": {}, "attributes": {},
            "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
            "connections": {"A": c["connections"]["Q"], "B": c["connections"]["D"], "S": [erow], "Y": [dnew]}}
        k += 1
        c["type"] = "$_DFFE_PP_"
        c["connections"]["D"] = [dnew]
        c["connections"]["E"] = [etab]
    print(f"table {t:10s} flops {len(members):5d} row enables {len(ens):4d}")
for t, members in sorted(groups.items()):
    if len(members) < min_flops:
        print(f"left fine-grained (fewer than {min_flops} enable flops): {t} {len(members)}")
json.dump(d, open(dst, "w"))
