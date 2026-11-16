#!/usr/bin/env python3
"""Lumped RC extraction of the routed wires in a DEF, written as SPEF.

This is not a sign-off extractor. The PDK has no extraction rules (no OpenRCX rules,
no capacitance tables, no layer thicknesses), so the only wire data available are the
per-layer R and C in the tech LEF, which are also what OpenROAD's estimate_parasitics
uses. What this script adds is that it uses the wires the detailed router actually
drew, instead of re-estimating them from global routing:

  per net:  C_wire = sum over routed segments of (L*W*CPERSQDIST + 2*L*EDGECAPACITANCE)
            R_wire = sum over routed segments of (L/W*RPERSQ) + sum over vias of R_via
  model:    half of C_wire on the driver node, the other half split evenly over the
            load nodes; every load is connected to the driver through R_wire (a star:
            pessimistic, each load sees the resistance of the whole net). No coupling.

usage: def2spef.py <tech.lef> <cells.lef> <routed.def> <out.spef>
"""
import re
import sys
from collections import defaultdict


def parse_tech(path):
    layers, vias, cur, kind = {}, {}, None, None
    for line in open(path):
        t = line.split()
        if not t:
            continue
        if t[0] == "LAYER" and len(t) == 2:
            cur, kind = t[1], "layer"
            layers[cur] = {}
        elif t[0] == "VIA" and len(t) >= 2:
            cur, kind = t[1], "via"
            vias[cur] = 0.0
        elif t[0] == "END" and len(t) == 2 and t[1] == cur:
            cur = None
        elif cur and kind == "layer":
            if t[0] == "WIDTH":
                layers[cur]["w"] = float(t[1])
            elif t[0] == "CAPACITANCE" and t[1] == "CPERSQDIST":
                layers[cur]["ca"] = float(t[2])
            elif t[0] == "EDGECAPACITANCE":
                layers[cur]["ce"] = float(t[1])
            elif t[0] == "RESISTANCE" and t[1] == "RPERSQ":
                layers[cur]["rs"] = float(t[2])
        elif cur and kind == "via" and t[0] == "RESISTANCE":
            vias[cur] = float(t[1])
    return {k: v for k, v in layers.items() if "rs" in v and "ca" in v}, vias


def parse_cell_dirs(path):
    dirs, macro, pin = {}, None, None
    for line in open(path):
        t = line.split()
        if not t:
            continue
        if t[0] == "MACRO":
            macro = t[1]
        elif t[0] == "PIN" and macro:
            pin = t[1]
        elif t[0] == "DIRECTION" and macro and pin:
            dirs[(macro, pin)] = t[1]
        elif t[0] == "END" and len(t) == 2 and t[1] == pin:
            pin = None
    return dirs


TRAILIDX = re.compile(r"(?<!\\)\[\d+(?<!\\)\]$")
UNESC = re.compile(r"(?<!\\)([\[\]])")


def spef_name(n):
    """DEF escapes most non-bus brackets, but OpenROAD writes some names (buffered
    output nets such as f_ckpt[19]4336) unescaped; escape any bracket that is not a
    trailing bus index so OpenSTA can find the net. A trailing unescaped index stays
    unescaped also when the stem has escaped brackets (ttag2\\[6\\][1], a bit of an
    escaped bus): escaping it made OpenSTA drop the net (STA-1650)."""
    m = TRAILIDX.search(n)
    stem, idx = (n[:m.start()], m.group(0)) if m else (n, "")
    return UNESC.sub(r"\\\1", stem) + idx


def main(tech, cells, deff, out):
    layers, vias = parse_tech(tech)
    cdir = parse_cell_dirs(cells)
    text = open(deff).read()
    dbu = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", text).group(1))
    design = re.search(r"^DESIGN (\S+)", text, re.M).group(1)
    comp = {}
    sec = text[text.index("\nCOMPONENTS"):text.index("END COMPONENTS")]
    for m in re.finditer(r"-\s+(\S+)\s+(\S+)", sec):
        comp[m.group(1)] = m.group(2)
    pdir = {}
    sec = text[text.index("\nPINS"):text.index("END PINS")]
    for m in re.finditer(r"-\s+(\S+)\s+\+\s+NET\s+\S+.*?\+\s+DIRECTION\s+(\S+)", sec, re.S):
        pdir[m.group(1)] = m.group(2)
    sec = text[text.index("\nNETS"):text.index("END NETS")]
    nets = sec.split(";\n")
    o = open(out, "w")
    o.write('*SPEF "IEEE 1481-1998"\n*DESIGN "%s"\n*DATE "-"\n*VENDOR "bp55"\n*PROGRAM "def2spef.py"\n'
            '*VERSION "0"\n*DESIGN_FLOW "NAME_SCOPE LOCAL" "PIN_CAP NONE"\n*DIVIDER /\n*DELIMITER :\n'
            '*BUS_DELIMITER [ ]\n*T_UNIT 1 NS\n*C_UNIT 1 PF\n*R_UNIT 1 OHM\n*L_UNIT 1 HENRY\n\n' % design)
    stats = defaultdict(float)
    nnet = 0
    for blk in nets:
        m = re.match(r"\s*-\s+(\S+)", blk)
        if not m or "+ ROUTED" not in blk:
            continue
        name = spef_name(m.group(1))
        head = blk.split("+ ROUTED")[0]
        conns = re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", head)
        if not conns:
            continue
        cw = rw = 0.0
        for seg in re.split(r"\+ ROUTED|\bNEW\b", blk.split("+ ROUTED", 1)[1]):
            seg = seg.strip()
            if not seg:
                continue
            lay = seg.split()[0]
            pts = re.findall(r"\(\s*(\S+)\s+(\S+)(?:\s+\S+)?\s*\)", seg)
            tail = seg.split(")")[-1].split()
            if tail and tail[0] in vias:
                rw += vias[tail[0]]
                stats["vias"] += 1
            if lay not in layers or len(pts) < 2 or "RECT" in seg:
                continue
            L = layers[lay]
            x0, y0 = pts[0]
            px, py = float(x0), float(y0)
            for x, y in pts[1:]:
                nx = px if x == "*" else float(x)
                ny = py if y == "*" else float(y)
                ln = (abs(nx - px) + abs(ny - py)) / dbu
                cw += ln * L["w"] * L["ca"] + 2 * ln * L["ce"]
                rw += ln / L["w"] * L["rs"]
                stats["len_" + lay] += ln
                px, py = nx, ny
        nodes = []
        for inst, pin in conns:
            if inst == "PIN":
                d = {"INPUT": "I", "OUTPUT": "O"}.get(pdir.get(pin, "INOUT"), "B")
                pin = spef_name(pin)
                nodes.append(("*P", pin, d, pin, d == "I"))
            else:
                d = {"INPUT": "I", "OUTPUT": "O"}.get(cdir.get((comp.get(inst), pin), "INOUT"), "B")
                nm = "%s:%s" % (spef_name(inst), pin)
                nodes.append(("*I", nm, d, nm, d == "O"))
        drv = [n for n in nodes if n[4]]
        if len(drv) != 1:
            stats["skipped_nets"] += 1
            continue
        drv = drv[0]
        loads = [n for n in nodes if n is not drv]
        nnet += 1
        stats["cap_pf"] += cw
        o.write("*D_NET %s %.6g\n*CONN\n" % (name, cw))
        for kind, nm, d, _, _ in nodes:
            o.write("%s %s %s\n" % (kind, nm, d))
        o.write("*CAP\n")
        k = 1
        o.write("%d %s %.6g\n" % (k, drv[3], cw / 2 if loads else cw))
        for ld in loads:
            k += 1
            o.write("%d %s %.6g\n" % (k, ld[3], cw / 2 / len(loads)))
        o.write("*RES\n")
        k = 0
        for ld in loads:
            k += 1
            o.write("%d %s %s %.6g\n" % (k, drv[3], ld[3], max(rw, 1e-3)))
        o.write("*END\n\n")
    o.close()
    lens = " ".join("%s %.0f um" % (k[4:], v) for k, v in sorted(stats.items()) if k.startswith("len_"))
    print("nets %d, skipped %d, total wire C %.1f pF, vias %d, %s" %
          (nnet, stats["skipped_nets"], stats["cap_pf"], stats["vias"], lens))


if __name__ == "__main__":
    main(*sys.argv[1:5])
