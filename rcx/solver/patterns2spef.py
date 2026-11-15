#!/usr/bin/env python3
"""Reference ("golden") parasitics of the OpenRCX bench_wires patterns, as SPEF.

This replaces the commercial reference extractor of the standard OpenRCX rules flow
(bench_wires -> reference extractor -> bench_read_spef -> write_rules) with the 2D
field solver in fd2d.py and the stack in stack.py.

Per pattern (net-name prefix such as O6_M3oM2_W100W100_S00200S00200):
  - the 1..5 parallel pattern wires become 2D conductors (drawn geometry shrunk 0.9x,
    corner width bias applied, z from the stack);
  - every context layer (cntxM<k> nets, orthogonal min-pitch wires) is a grounded
    plane in the cross-sections that cut through a context wire and absent in those
    that cut between them; the result is the density-weighted average of those
    cross-sections ("2.5D"). Coupling to context counts as ground capacitance, which
    is how write_rules treats it anyway (it moves cntxM coupling into ground);
  - totals = per-um values x silicon length (0.9 x drawn length); wire R from the
    LVS-deck resistor model at the corner temperature (stack.r_per_drawn_um).

usage: patterns2spef.py <patterns.def> <corner: typ|rcworst|rcbest> <out.spef> [jobs]
"""
import itertools
import os
import re
import sys
from collections import defaultdict
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fd2d import Problem, ground_and_coupling  # noqa: E402
from stack import SHRINK, Stack  # noqa: E402

DBU = 1000.0
LAYER_W = {"MET1": 0.09, "MET2": 0.1, "MET3": 0.1, "MET4": 0.1, "MET5": 0.1, "T4M2": 0.4}
H_FINE = 0.005

NET_RE = re.compile(r"^\s*-\s+(\S+)\s")
SEG_RE = re.compile(r"(?:ROUTED|NEW)\s+(\S+)\s+\(\s*(-?\d+)\s+(-?\d+)[^)]*\)\s+\(\s*(\S+)\s+(\S+)[^)]*\)")


def read_nets(path):
    nets = {}
    in_nets = False
    cur = None
    with open(path) as f:
        for line in f:
            if line.startswith("NETS"):
                in_nets = True
                continue
            if not in_nets:
                continue
            if line.startswith("END NETS"):
                break
            m = NET_RE.match(line)
            if m:
                cur = m.group(1)
                nets[cur] = []
            for s in SEG_RE.finditer(line):
                lay, x1, y1, x2, y2 = s.groups()
                x1, y1 = int(x1), int(y1)
                x2 = x1 if x2 == "*" else int(x2)
                y2 = y1 if y2 == "*" else int(y2)
                nets[cur].append((lay, x1 / DBU, y1 / DBU, x2 / DBU, y2 / DBU))
    return nets


def group_patterns(nets):
    groups = defaultdict(lambda: {"wires": {}, "ctx": defaultdict(list)})
    for name, segs in nets.items():
        m = re.match(r"^(.*)_cntx(M\d+)_(\d+)$", name)
        if m:
            groups[m.group(1)]["ctx"][m.group(2)].append((name, segs))
            continue
        m = re.match(r"^(.*)_(\d+)$", name)
        if m:
            groups[m.group(1)]["wires"][int(m.group(2))] = (name, segs)
    return groups


def solve_pattern(args):
    prefix, g, corner = args
    st = Stack(corner)
    out = {}
    wires = []
    for num, (name, segs) in sorted(g["wires"].items()):
        lay, x1, y1, x2, y2 = segs[0]
        horiz = abs(y2 - y1) < 1e-9
        lat = y1 if horiz else x1
        length = abs(x2 - x1) if horiz else abs(y2 - y1)
        wires.append((num, name, lay, lat, length, horiz))
    is_res = prefix.startswith("R6_")
    ctx_names = [n for lst in g["ctx"].values() for n, _ in lst]
    if is_res or not wires:
        for num, name, lay, lat, length, horiz in wires:
            out[name] = dict(cg=0.0, cc={}, r=st.r_per_drawn_um(lay, LAYER_W[lay]) * length)
        return prefix, out, ctx_names
    lat0 = sum(w[3] for w in wires) / len(wires)
    horiz = wires[0][5]
    # context layers: (layer, lateral span in silicon coordinates, density)
    ctx = []
    for _, lst in sorted(g["ctx"].items()):
        lay = lst[0][1][0][0]
        spans, pos = [], []
        for _, segs in lst:
            _, x1, y1, x2, y2 = segs[0]
            if horiz:  # target horizontal, context vertical: lateral span along y
                spans.append((min(y1, y2), max(y1, y2)))
                pos.append(x1)
            else:
                spans.append((min(x1, x2), max(x1, x2)))
                pos.append(y1)
        pos.sort()
        pitch = sorted(b - a for a, b in zip(pos[:-1], pos[1:]))[len(pos) // 2 - 1] if len(pos) > 1 else 1.0
        w = LAYER_W[lay]
        dens = min(1.0, (w * SHRINK + st.dw) / (pitch * SHRINK))
        lo = min(s[0] for s in spans)
        hi = max(s[1] for s in spans)
        ctx.append((lay, (lo - lat0) * SHRINK, (hi - lat0) * SHRINK, dens))
    nw = len(wires)
    cg = [0.0] * nw
    cc = [[0.0] * nw for _ in range(nw)]
    for present in itertools.product([0, 1], repeat=len(ctx)):
        wgt = 1.0
        for (lay, a, b, d), p in zip(ctx, present):
            wgt *= d if p else (1.0 - d)
        if wgt <= 0:
            continue
        pr = Problem(st.diel, h_fine=H_FINE)
        for num, name, lay, lat, length, _ in wires:
            ws = st.si_width(LAYER_W[lay])
            yc = (lat - lat0) * SHRINK
            z0, z1 = st.z(lay)
            pr.add(name, [(yc - ws / 2, yc + ws / 2, z0, z1)])
        for (lay, a, b, d), p in zip(ctx, present):
            if p:
                z0, z1 = st.z(lay)
                pr.add("ctx_" + lay, [(a, b, z0, z1)])
        C = pr.solve()
        g_, c_ = ground_and_coupling(C)
        for i in range(nw):
            # ground = own Maxwell row sum + coupling to (grounded) context planes
            cg[i] += wgt * (g_[i] + sum(c_[i, j] for j in range(nw, C.shape[0])))
            for j in range(nw):
                cc[i][j] += wgt * c_[i, j]
    for i, (num, name, lay, lat, length, _) in enumerate(wires):
        lsi = length * SHRINK
        out[name] = dict(cg=cg[i] * lsi,
                         cc={wires[j][1]: cc[i][j] * lsi for j in range(nw) if j != i and cc[i][j] > 0},
                         r=st.r_per_drawn_um(lay, LAYER_W[lay]) * length,
                         cpu=(cg[i], {wires[j][1]: cc[i][j] for j in range(nw) if j != i}))
    return prefix, out, ctx_names


def write_spef(path, results, all_nets):
    with open(path, "w") as f:
        f.write('*SPEF "IEEE 1481-1998"\n*DESIGN "blk"\n*DATE "-"\n*VENDOR "bp55-rcx"\n'
                '*PROGRAM "patterns2spef fd2d"\n*VERSION "1"\n*DESIGN_FLOW "PIN_CAP NONE"\n'
                '*DIVIDER /\n*DELIMITER :\n*BUS_DELIMITER [ ]\n'
                '*T_UNIT 1 NS\n*C_UNIT 1 FF\n*R_UNIT 1 OHM\n*L_UNIT 1 HENRY\n\n*PORTS\n')
        for n in all_nets:
            f.write(f"{n} O\n{n}_BL I\n")
        f.write("\n")
        for n in all_nets:
            d = results.get(n, dict(cg=0.0, cc={}, r=1.0))
            tot = d["cg"] + sum(d["cc"].values())
            f.write(f"*D_NET {n} {tot:.6g}\n*CONN\n*P {n} O\n*P {n}_BL I\n*CAP\n")
            k = 1
            f.write(f"{k} {n} {d['cg']/2:.6g}\n"); k += 1
            f.write(f"{k} {n}_BL {d['cg']/2:.6g}\n"); k += 1
            for o, v in sorted(d["cc"].items()):
                f.write(f"{k} {n} {o} {v/2:.6g}\n"); k += 1
                f.write(f"{k} {n}_BL {o}_BL {v/2:.6g}\n"); k += 1
            f.write(f"*RES\n1 {n} {n}_BL {d['r']:.6g}\n*END\n\n")


def main():
    defp, corner, outp = sys.argv[1:4]
    jobs = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    nets = read_nets(defp)
    groups = group_patterns(nets)
    tasks = [(p, {"wires": g["wires"], "ctx": dict(g["ctx"])}, corner) for p, g in sorted(groups.items())]
    results = {}
    log = open(outp + ".log", "w")
    with Pool(jobs) as pool:
        for i, (prefix, out, _) in enumerate(pool.imap_unordered(solve_pattern, tasks, chunksize=2)):
            results.update(out)
            for name, d in sorted(out.items()):
                if "cpu" in d:
                    cgu, ccu = d["cpu"]
                    log.write(f"{name} cg_per_um {cgu:.5f} " + " ".join(f"cc[{k.rsplit('_',1)[1]}] {v:.5f}" for k, v in sorted(ccu.items())) + "\n")
            if i % 50 == 0:
                print(f"{i}/{len(tasks)} patterns", flush=True)
    log.close()
    write_spef(outp, results, sorted(nets))


if __name__ == "__main__":
    main()
