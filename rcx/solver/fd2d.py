"""Compact 2D finite-volume Laplace solver for interconnect cross-sections.

Geometry is a cross-section (y lateral, z vertical) of infinitely long, parallel
conductors embedded in planar dielectric layers. Units: micrometres; results are
capacitance per unit length in fF/um.

Discretisation: node-centred finite volumes (box integration) on a non-uniform
tensor grid. Every rectangle edge and every dielectric interface is a grid line,
so the permittivity jump is exact on the dual faces. Conductors are Dirichlet
node sets. Boundary conditions: z = 0 is a grounded plane (the substrate);
the top and the two side walls are Neumann (zero normal flux), placed far enough
away that they do not matter (see validation/solver_validation.py).

The Maxwell capacitance matrix is obtained from the discrete Gauss law: with
conductor k at 1 V and all others (and ground) at 0 V, the charge on conductor j
is the net flux leaving its node set, Q_j = sum_n (L V)_n over the nodes of j.
This is exact for the discrete problem (no numerical flux integration path).
"""
import math

import numpy as np
import scipy.sparse as sp
import scipy.sparse.linalg as spla

EPS0 = 8.8541878128e-3  # fF/um


def _axis(keys, lo, hi, h_fine, h_coarse, grow, near):
    """Non-uniform 1D grid between lo and hi containing every key coordinate.

    Cell size is h_fine within `near` intervals (list of (a, b) of conductor
    extents along this axis) and grows geometrically (factor `grow`) with the
    distance from them, capped at h_coarse.
    """
    keys = sorted(set([lo, hi] + [k for k in keys if lo <= k <= hi]))

    def hloc(x):
        d = min((0.0 if a <= x <= b else min(abs(x - a), abs(x - b))) for a, b in near) if near else 1e9
        # geometric growth: h = h_fine * grow^(d / h_fine) capped, but linear is enough
        return min(h_coarse, h_fine + (grow - 1.0) * d)

    pts = [keys[0]]
    for a, b in zip(keys[:-1], keys[1:]):
        L = b - a
        if L <= 0:
            continue
        x = a
        seg = [a]
        while True:
            h = min(hloc(x), hloc(min(b, x + hloc(x))))
            if x + h >= b - 1e-9:
                break
            x += h
            seg.append(x)
        # redistribute so that the interval is filled evenly-ish: keep generated points
        # but make sure the last cell is not a sliver
        if len(seg) > 1 and (b - seg[-1]) < 0.3 * (seg[-1] - seg[-2]):
            seg.pop()
        pts.extend(seg[1:])
        pts.append(b)
    return np.array(sorted(set(np.round(pts, 9))))


class Problem:
    """A cross-section: dielectric layers and conductors."""

    def __init__(self, dielectrics, h_fine=0.005, h_coarse=0.25, grow=1.25):
        # dielectrics: list of (z_bottom, z_top, eps_r), covering [0, ztop]
        self.diel = sorted(dielectrics)
        self.cond = []  # list of (name, [rects]) rect = (y0, y1, z0, z1)
        self.h_fine, self.h_coarse, self.grow = h_fine, h_coarse, grow
        self.side_margin = 3.0
        self.top_margin = None

    def add(self, name, rects):
        self.cond.append((name, list(rects)))

    def eps_at(self, z):
        for z0, z1, e in self.diel:
            if z0 <= z < z1:
                return e
        return self.diel[-1][2]

    def solve(self):
        rects = [r for _, rs in self.cond for r in rs]
        ymin = min(r[0] for r in rects) - self.side_margin
        ymax = max(r[1] for r in rects) + self.side_margin
        ztop = self.diel[-1][1]
        ykeys = [v for r in rects for v in (r[0], r[1])]
        zkeys = [v for r in rects for v in (r[2], r[3])] + [d[0] for d in self.diel] + [d[1] for d in self.diel]
        ynear = [(r[0], r[1]) for r in rects]
        znear = [(r[2], r[3]) for r in rects]
        y = _axis(ykeys, ymin, ymax, self.h_fine, self.h_coarse, self.grow, ynear)
        z = _axis(zkeys, 0.0, ztop, self.h_fine, self.h_coarse, self.grow, znear)
        ny, nz = len(y), len(z)
        dy, dz = np.diff(y), np.diff(z)
        zc = 0.5 * (z[:-1] + z[1:])
        epsc = np.array([self.eps_at(v) for v in zc])  # per z-cell (planar layers)
        N = ny * nz
        idx = lambda i, j: i * nz + j  # noqa: E731
        # half-widths of dual cells
        hy = np.zeros(ny)
        hy[:-1] += dy / 2
        hy[1:] += dy / 2
        rows, cols, vals = [], [], []
        # y-edges (i,j)-(i+1,j): flux area = sum over the z-cells adjacent to node j
        ez_lo = np.zeros(nz)  # eps * dz/2 from the cell below node j
        ez_hi = np.zeros(nz)
        ez_lo[1:] = epsc * dz / 2
        ez_hi[:-1] = epsc * dz / 2
        area_y = ez_lo + ez_hi  # per node j
        I, J = np.meshgrid(np.arange(ny - 1), np.arange(nz), indexing="ij")
        g = (area_y[J] / dy[I]).ravel()
        a = (I * nz + J).ravel()
        b = ((I + 1) * nz + J).ravel()
        rows += [a, b]; cols += [b, a]; vals += [-g, -g]
        diag = np.zeros(N)
        np.add.at(diag, a, g)
        np.add.at(diag, b, g)
        # z-edges (i,j)-(i,j+1): eps of cell j times dual width hy[i] / dz[j]
        I, J = np.meshgrid(np.arange(ny), np.arange(nz - 1), indexing="ij")
        g = (epsc[J] * hy[I] / dz[J]).ravel()
        a = (I * nz + J).ravel()
        b = (I * nz + J + 1).ravel()
        rows += [a, b]; cols += [b, a]; vals += [-g, -g]
        np.add.at(diag, a, g)
        np.add.at(diag, b, g)
        rows.append(np.arange(N)); cols.append(np.arange(N)); vals.append(diag)
        L = sp.csr_matrix((np.concatenate(vals), (np.concatenate(rows), np.concatenate(cols))), shape=(N, N))
        L = L * EPS0
        # conductor node sets
        label = -np.ones(N, dtype=int)
        Y, Z = np.meshgrid(y, z, indexing="ij")
        Yf, Zf = Y.ravel(), Z.ravel()
        tol = 1e-9
        for k, (_, rs) in enumerate(self.cond):
            for (y0, y1, z0, z1) in rs:
                m = (Yf >= y0 - tol) & (Yf <= y1 + tol) & (Zf >= z0 - tol) & (Zf <= z1 + tol)
                label[m] = k
        ground = np.abs(Zf) < tol
        fixed = (label >= 0) | ground
        free = ~fixed
        Lff = L[free][:, free].tocsc()
        Lfc = L[free][:, fixed]
        lu = spla.splu(Lff)
        nc = len(self.cond)
        C = np.zeros((nc, nc))
        fixed_idx = np.where(fixed)[0]
        for k in range(nc):
            Vc = (label[fixed_idx] == k).astype(float)
            Vf = lu.solve(-(Lfc @ Vc))
            V = np.zeros(N)
            V[free] = Vf
            V[fixed_idx] = Vc
            Q = L @ V
            for j in range(nc):
                C[j, k] = Q[label == j].sum()
        self.grid = (ny, nz)
        return 0.5 * (C + C.T)  # Maxwell matrix, fF/um (symmetrised; asymmetry is ~1e-12)


def ground_and_coupling(C):
    """Maxwell matrix -> (ground cap per conductor, coupling matrix)."""
    cg = C.sum(axis=1)
    cc = -C.copy()
    np.fill_diagonal(cc, 0.0)
    return cg, cc


def sakurai_tamaru_single(w, t, h, eps_r):
    """Sakurai & Tamaru, IEEE TED 30(2) 1983: line over ground plane, fF/um."""
    return EPS0 * eps_r * (1.15 * (w / h) + 2.80 * (t / h) ** 0.222)


def hammerstad_microstrip_c(w, h, eps_r=1.0, t=0.0):
    """Zero-thickness microstrip in a homogeneous medium (Hammerstad 1975 /
    Wheeler), C = sqrt(eps)/(c Z0) with Z0 for eps_r = 1. Quoted accuracy ~1 %."""
    u = w / h
    if t > 0:
        # Hammerstad-Jensen 1980 strip-thickness correction (homogeneous medium)
        tn = t / h
        u += tn / math.pi * math.log(1.0 + 4.0 * math.e / (tn / math.tanh(math.sqrt(6.517 * u)) ** 2))
    if u <= 1:
        z0 = 60.0 * math.log(8.0 / u + u / 4.0)
    else:
        z0 = 120.0 * math.pi / (u + 1.393 + 0.667 * math.log(u + 1.444))
    c0 = 299792458.0
    # C per metre in air, then F/m -> fF/um (1 F/m = 1e15 fF / 1e6 um = 1e9 fF/um)
    return eps_r / (c0 * z0) * 1e9
