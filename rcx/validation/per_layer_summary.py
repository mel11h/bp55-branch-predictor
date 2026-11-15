"""Per-layer R and C per micrometre of a minimum-width wire, per RC corner, from the stack
and 2D solver used for the rules, next to the tech-LEF values.

Values are per DRAWN micrometre (the length unit of the LEF/DEF and of STA wire lengths);
the silicon wire is 0.9x shorter and narrower, which is included.
Environments for C:
  isolated : single wire, nothing but the substrate
  dense    : neighbours at minimum spacing on both sides (5 wires), and the layers directly
             below and above filled with orthogonal minimum-pitch wires (density 0.5, 2.5D
             average); MET1 has the substrate below, MET5 nothing above (no T4M2 wiring)
LEF C = W*CPERSQDIST + 2*EDGECAPACITANCE (pnr/... set_wire_rc takes its per-um values from these).

usage: python3 rcx/validation/per_layer_summary.py  (writes per_layer_summary.txt)
"""
import itertools
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "solver"))
from fd2d import Problem, ground_and_coupling  # noqa: E402
from stack import SHRINK, Stack  # noqa: E402

LAYERS = ["MET1", "MET2", "MET3", "MET4", "MET5"]
W = {"MET1": 0.09, "MET2": 0.1, "MET3": 0.1, "MET4": 0.1, "MET5": 0.1}
SP = {"MET1": 0.09, "MET2": 0.1, "MET3": 0.1, "MET4": 0.1, "MET5": 0.1}
LEF = {  # N551P6M_ecos.lef: RPERSQ, CPERSQDIST (pF/um2), EDGECAPACITANCE (pF/um)
    "MET1": (0.1122, 0.0007630, 0.0000339), "MET2": (0.0914, 0.0011069, 0.0000391),
    "MET3": (0.0914, 0.0011069, 0.0000409), "MET4": (0.0914, 0.0011069, 0.0000409),
    "MET5": (0.0914, 0.0006259, 0.0000344)}


def cap(st, lay, dense):
    w = st.si_width(W[lay])
    p = (W[lay] + SP[lay]) * SHRINK
    offs = [-2, -1, 0, 1, 2] if dense else [0]
    i = LAYERS.index(lay)
    ctx = []
    if dense:
        if i > 0:
            ctx.append(LAYERS[i - 1])
        if i < len(LAYERS) - 1:
            ctx.append(LAYERS[i + 1])
    tot = cc_n = 0.0
    for present in itertools.product([0, 1], repeat=len(ctx)):
        wgt = 1.0
        pr = Problem(st.diel, h_fine=0.005)
        z0, z1 = st.z(lay)
        for k in offs:
            pr.add(f"w{k}", [(k * p - w / 2, k * p + w / 2, z0, z1)])
        for c, on in zip(ctx, present):
            d = st.si_width(W[c]) / ((W[c] + SP[c]) * SHRINK)
            wgt *= d if on else 1 - d
            if on:
                a, b = st.z(c)
                pr.add("ctx", [(-3.0, 3.0, a, b)])
        cg, cc = ground_and_coupling(pr.solve())
        j = offs.index(0)
        n = len(offs)
        tot += wgt * (cg[j] + cc[j, :].sum())
        cc_n += wgt * cc[j, :n].sum()
    return tot * SHRINK, cc_n * SHRINK  # per drawn um


def main():
    out = ["per drawn um, minimum width; C in fF/um, R in ohm/um",
           "corner  layer  R(rcx)  R(LEF)  C_iso  C_dense  (coupling share)  C(LEF)"]
    for corner in ("typ", "rcworst", "rcbest"):
        st = Stack(corner)
        for lay in LAYERS:
            r = st.r_per_drawn_um(lay, W[lay])
            rs, ca, ce = LEF[lay]
            ci, _ = cap(st, lay, False)
            cd, cn = cap(st, lay, True)
            clef = (W[lay] * ca + 2 * ce) * 1000
            out.append(f"{corner:7s} {lay:5s} {r:6.3f}  {rs/W[lay]:6.3f}  {ci:.4f} {cd:.4f}  ({100*cn/cd:3.0f} %)  {clef:.4f}")
            print(out[-1], flush=True)
    with open(os.path.join(HERE, "per_layer_summary.txt"), "w") as f:
        f.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
