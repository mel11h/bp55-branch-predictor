"""How much does metal fill add to a signal wire if the fill is floating, versus grounded?

2D (typical stack) cross-section of a MET3 signal wire (min width) with
  - same-layer OPC fill bars (pnr/flow/fill_rules.json: 0.22 um wide, 0.30 um from
    signal metal, 0.25 um fill-to-fill), two on each side, parallel to the wire;
  - optionally MET2 and MET4 fill bars (orthogonal to the wire, 0.22 um wide at a
    0.47 um pitch): 2.5D average of the slices through a bar (weight 0.22/0.47) and
    between bars.
Every fill bar is its own conductor. Grounded fill: the wire's Maxwell self-term with
fill at 0 V. Floating fill: the fill nodes are eliminated with zero net charge,
C_eff = C_ww - C_wf C_ff^-1 C_fw. All drawn sizes are shrunk 0.9x.

usage: python3 rcx/validation/fill_floating_vs_grounded.py  (writes fill_floating_vs_grounded.txt)
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "solver"))
from fd2d import Problem  # noqa: E402
from stack import SHRINK, Stack  # noqa: E402

st = Stack("typ")
out = []


def wire_cap(same_layer, other_layers, neighbours):
    s = SHRINK
    pr = Problem(st.diel, h_fine=0.005)
    w = 0.1 * s
    z0, z1 = st.z("MET3")
    pr.add("sig", [(-w / 2, w / 2, z0, z1)])
    nfix = 1
    if neighbours:  # signal neighbours at 1.0 um drawn, grounded (other nets)
        for yc in (-1.0 * s, 1.0 * s):
            pr.add("nb", [(yc - w / 2, yc + w / 2, z0, z1)])
            nfix += 1
    fills = []
    if same_layer:
        fw, gap, ff = 0.22 * s, 0.30 * s, 0.25 * s
        for side in (-1, 1):
            y = w / 2 + gap
            for _ in range(2):
                a, b = y, y + fw
                if neighbours and b > 1.0 * s - w / 2 - gap:
                    break
                lo, hi = (a, b) if side > 0 else (-b, -a)
                pr.add("fill", [(lo, hi, z0, z1)])
                fills.append(len(pr.cond) - 1)
                y = b + ff
    for lay in other_layers:  # slice through an orthogonal fill bar: a 0.8 um long segment
        za, zb = st.z(lay)
        pr.add("fill", [(-0.40, 0.40, za, zb)])
        fills.append(len(pr.cond) - 1)
    C = pr.solve()
    grounded = C[0, 0]
    if fills:
        f = fills
        Cff = C[np.ix_(f, f)]
        Cwf = C[0, f]
        floating = C[0, 0] - Cwf @ np.linalg.solve(Cff, Cwf)
    else:
        floating = grounded
    return grounded, floating


def log(s):
    print(s)
    out.append(s)


for nb in (False, True):
    base, _ = wire_cap(False, [], nb)
    g1, f1 = wire_cap(True, [], nb)
    gm, fm = wire_cap(True, ["MET2", "MET4"], nb)
    d = 0.22 / 0.47
    g2 = d * gm + (1 - d) * g1
    f2 = d * fm + (1 - d) * f1
    env = "grounded signal neighbours at 1.0 um" if nb else "no signal neighbours"
    log(f"MET3 wire, {env}: no fill {base:.4f} fF/um")
    log(f"  same-layer fill        grounded {g1:.4f} (+{100*(g1/base-1):.1f} %)  floating {f1:.4f} (+{100*(f1/base-1):.1f} %)")
    log(f"  + MET2/MET4 fill (2.5D) grounded {g2:.4f} (+{100*(g2/base-1):.1f} %)  floating {f2:.4f} (+{100*(f2/base-1):.1f} %)")
    log(f"  floating/grounded increase ratio: {(f2-base)/max(g2-base,1e-12):.2f}")
with open(os.path.join(HERE, "fill_floating_vs_grounded.txt"), "w") as fh:
    fh.write("\n".join(out) + "\n")
