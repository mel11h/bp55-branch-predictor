"""Validation of rcx/solver/fd2d.py against closed-form cases.

1. Parallel plate, one dielectric: side walls are Neumann, so with the plate
   spanning the whole width the field is uniform and C = eps W / d exactly.
2. Parallel plate, two dielectrics in series: C = W / (d1/eps1 + d2/eps2), exact.
   Checks the permittivity-interface treatment.
3. Thin microstrip (t = w/50) in a homogeneous dielectric versus Hammerstad-Jensen (with strip-thickness correction)
   closed form (quoted accuracy about 1 %), for w/h from 0.25 to 4.
4. Finite-thickness line over a plane versus Sakurai-Tamaru (quoted ~6 %).
5. Grid convergence and boundary-distance check on a 55 nm-like 3-wire case.

usage: python3 rcx/validation/solver_validation.py  (writes solver_validation.txt next to it)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "solver"))
from fd2d import (EPS0, Problem, ground_and_coupling,  # noqa: E402
                  hammerstad_microstrip_c, sakurai_tamaru_single)

out = []


def log(s):
    print(s)
    out.append(s)


def pp_single():
    W, d, er = 2.0, 0.2, 3.9
    p = Problem([(0.0, d, er)], h_fine=0.01)
    p.side_margin = 0.0
    p.add("top", [(0.0, W, d, d)])
    C = p.solve()
    exact = EPS0 * er * W / d
    log(f"1 parallel plate      W={W} d={d} er={er}: solver {C[0,0]:.6f} fF/um exact {exact:.6f}  err {100*(C[0,0]/exact-1):+.4f} %")


def pp_series():
    W, d1, e1, d2, e2 = 2.0, 0.05, 4.9, 0.2, 2.9
    p = Problem([(0.0, d1, e1), (d1, d1 + d2, e2)], h_fine=0.01)
    p.side_margin = 0.0
    p.add("top", [(0.0, W, d1 + d2, d1 + d2)])
    C = p.solve()
    exact = EPS0 * W / (d1 / e1 + d2 / e2)
    log(f"2 series dielectrics  W={W} {d1}@{e1} + {d2}@{e2}: solver {C[0,0]:.6f} exact {exact:.6f}  err {100*(C[0,0]/exact-1):+.4f} %")


def microstrip():
    h = 0.4
    for u in (0.25, 0.5, 1.0, 2.0, 4.0):
        w = u * h
        t = w / 50
        p = Problem([(0.0, h + 12.0, 1.0)], h_fine=min(0.004, t), h_coarse=0.5, grow=1.2)
        p.side_margin = 12.0
        p.add("strip", [(0.0, w, h, h + t)])
        C = p.solve()[0, 0]
        ref = hammerstad_microstrip_c(w, h, t=t)
        log(f"3 microstrip w/h={u:<4} t=w/50  solver {C:.5f} fF/um Hammerstad-Jensen (t-corrected) {ref:.5f}  err {100*(C/ref-1):+.2f} %  grid {p.grid}")


def sakurai():
    for (w, t, h) in ((0.1, 0.22, 0.25), (0.2, 0.22, 0.25), (0.5, 0.22, 0.5), (1.0, 0.22, 0.25)):
        p = Problem([(0.0, h + t + 10.0, 2.9)], h_fine=0.004, h_coarse=0.5, grow=1.2)
        p.side_margin = 10.0
        p.add("w", [(0.0, w, h, h + t)])
        C = p.solve()[0, 0]
        ref = sakurai_tamaru_single(w, t, h, 2.9)
        log(f"4 line over plane w={w} t={t} h={h}: solver {C:.5f} Sakurai-Tamaru {ref:.5f}  diff {100*(C/ref-1):+.1f} % (formula quoted +-6 %)")


def convergence():
    # three min-pitch lines (silicon 0.09/0.18), t=0.22, 0.25 above ground, plane 0.25 above
    def run(hf, margin, top):
        z0 = 0.25
        p = Problem([(0.0, 0.25, 4.9), (0.25, z0 + 0.22 + top, 2.9)], h_fine=hf)
        p.side_margin = margin
        for k, yc in enumerate((-0.18, 0.0, 0.18)):
            p.add(f"w{k}", [(yc - 0.045, yc + 0.045, z0, z0 + 0.22)])
        cg, cc = ground_and_coupling(p.solve())
        return cg[1], cc[1, 0], p.grid
    log("5 convergence, 3 lines w=0.09 s=0.09 t=0.22, centre wire (ground, coupling to one neighbour) fF/um:")
    for hf in (0.01, 0.005, 0.0025):
        g, c, grid = run(hf, 3.0, 3.0)
        log(f"   h_fine={hf:<7} margin 3 um top 3 um: Cg {g:.5f} Cc {c:.5f}  grid {grid}")
    for m in (1.5, 6.0):
        g, c, grid = run(0.005, m, m)
        log(f"   h_fine=0.005   margin {m} um top {m} um: Cg {g:.5f} Cc {c:.5f}")


if __name__ == "__main__":
    pp_single()
    pp_series()
    microstrip()
    sakurai()
    convergence()
    with open(os.path.join(HERE, "solver_validation.txt"), "w") as f:
        f.write("\n".join(out) + "\n")
