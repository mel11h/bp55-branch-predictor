"""Does the rules deck generalise beyond the bench patterns it was fitted to?

Builds small test layouts that are NOT bench_wires patterns (other context densities,
asymmetric neighbours, wires on both sides), computes the reference capacitance of the
target MET3 wire with the 2D solver (orthogonal context wires: density-weighted 2.5D,
the same physics as the reference), extracts them with OpenRCX and the typical rules,
and compares the target wire's total capacitance.

usage: python3 rcx/validation/generalization.py <work_dir>
  needs openroad on PATH and BP55_ROOT; writes generalization.txt next to this script.
"""
import itertools
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "solver"))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
from compare_spef import read_spef  # noqa: E402
from fd2d import Problem, ground_and_coupling  # noqa: E402
from stack import SHRINK, Stack  # noqa: E402

W = {"MET2": 0.1, "MET3": 0.1, "MET4": 0.1}
LEN = 20.0  # target length, drawn um

# case: (name, parallel MET3 neighbour offsets (centre-centre, drawn), {ctx layer: pitch})
CASES = [
    ("alone over substrate", [], {}),
    ("over MET2 pitch 0.2 (density 0.5)", [], {"MET2": 0.2}),
    ("over MET2 pitch 0.4 (density 0.25)", [], {"MET2": 0.4}),
    ("over MET2 pitch 0.8 (density 0.125)", [], {"MET2": 0.8}),
    ("under MET4 pitch 0.4", [], {"MET4": 0.4}),
    ("MET2 0.4 below + MET4 0.4 above", [], {"MET2": 0.4, "MET4": 0.4}),
    ("neighbours s=0.1 both sides, MET2 0.4", [-0.2, 0.2], {"MET2": 0.4}),
    ("neighbours s=0.15 and s=0.5, MET2 0.3", [-0.25, 0.6], {"MET2": 0.3}),
    ("neighbours s=0.3 both sides, MET2+MET4 0.6", [-0.4, 0.4], {"MET2": 0.6, "MET4": 0.6}),
    ("one neighbour s=0.1, no context", [0.2], {}),
]


def reference(st, nbrs, ctx):
    wires = [0.0] + list(nbrs)
    tot = 0.0
    layers = sorted(ctx)
    for present in itertools.product([0, 1], repeat=len(layers)):
        wgt = 1.0
        pr = Problem(st.diel, h_fine=0.005)
        for k, yc in enumerate(wires):
            ws = st.si_width(W["MET3"])
            z0, z1 = st.z("MET3")
            pr.add(f"w{k}", [(yc * SHRINK - ws / 2, yc * SHRINK + ws / 2, z0, z1)])
        for lay, p in zip(layers, present):
            d = st.si_width(W[lay]) / (ctx[lay] * SHRINK)
            wgt *= d if p else 1 - d
            if p:
                z0, z1 = st.z(lay)
                pr.add("ctx", [(-1.5 * SHRINK, 1.5 * SHRINK, z0, z1)])
        C = pr.solve()
        cg, cc = ground_and_coupling(C)
        tot += wgt * (cg[0] + cc[0, 1:].sum())
    return tot * LEN * SHRINK


def write_def(path, nbrs, ctx):
    dbu = 1000
    nets, pins = [], []
    x0, x1, yc = 5000, 5000 + int(LEN * dbu), 10000

    def add(name, layer, a, b, horiz, pos):
        if horiz:
            seg = f"( {a} {pos} 0 ) ( {b} * 0 )"
            p1, p2 = (a, pos), (b, pos)
        else:
            seg = f"( {pos} {a} 0 ) ( * {b} 0 )"
            p1, p2 = (pos, a), (pos, b)
        nets.append(f"    - {name} ( PIN {name} ) ( PIN {name}_BL ) + USE SIGNAL\n      + ROUTED {layer} {seg} ;")
        for pn, (x, y) in ((name, p1), (name + "_BL", p2)):
            pins.append(f"    - {pn} + NET {name} + DIRECTION {'OUTPUT' if pn == name else 'INPUT'} + USE SIGNAL\n"
                        f"      + PORT\n        + LAYER {layer} ( -50 -50 ) ( 50 50 )\n        + PLACED ( {x} {y} ) N ;")
    add("t", "MET3", x0, x1, True, yc)
    for k, off in enumerate(nbrs):
        add(f"n{k}", "MET3", x0, x1, True, yc + int(round(off * dbu)))
    for lay, pitch in ctx.items():
        p = int(round(pitch * dbu))
        for k, x in enumerate(range(x0 + p // 2, x1, p)):
            add(f"c{lay}_{k}", lay, yc - 1500, yc + 1500, False, x)
    with open(path, "w") as f:
        f.write("VERSION 5.8 ;\nDIVIDERCHAR \"/\" ;\nBUSBITCHARS \"[]\" ;\nDESIGN gen ;\nUNITS DISTANCE MICRONS 1000 ;\n"
                "DIEAREA ( 0 0 ) ( 30000 20000 ) ;\nCOMPONENTS 0 ;\nEND COMPONENTS\n")
        f.write(f"PINS {len(pins)} ;\n" + "\n".join(pins) + "\nEND PINS\n")
        f.write(f"NETS {len(nets)} ;\n" + "\n".join(nets) + "\nEND NETS\nEND DESIGN\n")


def main():
    wd = os.path.abspath(sys.argv[1])
    os.makedirs(wd, exist_ok=True)
    root = os.environ["BP55_ROOT"]
    st = Stack("typ")
    out = ["target MET3 wire, 20 um drawn; total capacitance (fF): reference 2D/2.5D solver vs OpenRCX typ rules"]
    for i, (name, nbrs, ctx) in enumerate(CASES):
        d = os.path.join(wd, f"case{i}.def")
        write_def(d, nbrs, ctx)
        tcl = os.path.join(wd, f"case{i}.tcl")
        with open(tcl, "w") as f:
            f.write(f"read_lef {root}/pdk/prtech/techLEF/N551P6M_ecos.lef\nread_def {d}\n"
                    "define_process_corner -ext_model_index 0 X\n"
                    f"extract_parasitics -ext_model_file {root}/rcx/rules/bp55_typ.rules -max_res 0 -coupling_threshold 0.0 -cc_model 12 -context_depth 5\n"
                    f"write_spef {wd}/case{i}.spef\n")
        subprocess.run(["openroad", "-threads", "1", "-no_init", "-exit", tcl], cwd=wd,
                       stdout=open(os.path.join(wd, f"case{i}.log"), "w"), stderr=subprocess.STDOUT, check=True)
        ext = read_spef(os.path.join(wd, f"case{i}.spef"))["t"][0]
        ref = reference(st, nbrs, ctx)
        out.append(f"  {name:45s} ref {ref:7.3f}  OpenRCX {ext:7.3f}  ratio {ext/ref:.3f}")
        print(out[-1], flush=True)
    with open(os.path.join(HERE, "generalization.txt"), "w") as f:
        f.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
