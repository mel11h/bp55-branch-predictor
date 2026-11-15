# Windowed metal density of a GDS, computed the way the ICsprout55 Calibre deck checks it
# (pv/DRC/ICsprout_CalDRC_55LLULP1233_REV1_0_OS.drc, rules MET1_D_1, Mn_D_1, Mn_D_3,
# T4M2_D_1): density of (drawn metal OR dummy metal) in a 100 um x 100 um window moved in
# 50 um steps over the layout extent, windows that would cross the edge backed up to fit
# (BACKUP), and the density difference between adjacent windows (GRADIENT, deck limit 0.20).
#
# run:  klayout -b -r density.py -rd gds=<file.gds> -rd out=<report.txt>
import pya

LAYERS = [  # name, drawn (layer, datatype), dummy (layer, datatype), min, max
    ("MET1", (81, 1), (81, 2), 0.10, 0.80),
    ("MET2", (82, 1), (82, 2), 0.10, 0.80),
    ("MET3", (83, 1), (83, 2), 0.10, 0.80),
    ("MET4", (84, 1), (84, 2), 0.10, 0.80),
    ("MET5", (85, 1), (85, 2), 0.10, 0.80),
    ("T4M2", (103, 1), (103, 2), 0.20, 0.85),
]
WIN, STEP, GRAD = 100.0, 50.0, 0.20

ly = pya.Layout()
ly.read(gds)
top = ly.top_cell()
dbu = ly.dbu
box = top.bbox()
x0, y0, x1, y1 = box.left * dbu, box.bottom * dbu, box.right * dbu, box.top * dbu


def starts(a, b):
    s, v = [], a
    while v + WIN < b - 1e-6:
        s.append(v)
        v += STEP
    s.append(max(a, b - WIN))  # BACKUP: last window moved back inside the extent
    return sorted(set(round(t, 3) for t in s))


xs, ys = starts(x0, x1), starts(y0, y1)
out = open(out, "w")
out.write("layout %s, extent %.2f x %.2f um, %d x %d windows of %.0f um, step %.0f um\n"
          % (top.name, x1 - x0, y1 - y0, len(xs), len(ys), WIN, STEP))
out.write("%-5s %8s %8s %8s %8s %6s %6s %9s %7s %9s %9s\n" % (
    "layer", "min", "mean", "max", "chip", "limlo", "limhi", "win<min", "win>max", "maxgrad", "grad>0.2"))
for name, drawn, dummy, lo, hi in LAYERS:
    reg = pya.Region()
    for ld in (drawn, dummy):
        li = ly.find_layer(ld[0], ld[1])
        if li is not None:
            reg += pya.Region(top.begin_shapes_rec(li))
    nfill = 0
    li = ly.find_layer(dummy[0], dummy[1])
    if li is not None:
        nfill = pya.Region(top.begin_shapes_rec(li)).count()
    reg.merge()
    dens = {}
    for ix, x in enumerate(xs):
        for iy, y in enumerate(ys):
            w = pya.Box(int(round(x / dbu)), int(round(y / dbu)), int(round((x + WIN) / dbu)), int(round((y + WIN) / dbu)))
            dens[(ix, iy)] = (reg & pya.Region(w)).area() * dbu * dbu / (WIN * WIN)
    vals = list(dens.values())
    grad = 0.0
    for (ix, iy), d in dens.items():
        for nb in ((ix + 1, iy), (ix, iy + 1)):
            if nb in dens:
                grad = max(grad, abs(d - dens[nb]))
    ngrad = sum(1 for (ix, iy), d in dens.items() for nb in ((ix + 1, iy), (ix, iy + 1))
                if nb in dens and abs(d - dens[nb]) > GRAD)
    chip = reg.area() * dbu * dbu / ((x1 - x0) * (y1 - y0))
    out.write("%-5s %8.3f %8.3f %8.3f %8.3f %6.2f %6.2f %9d %7d %9.3f %9d   fill shapes %d\n" % (
        name, min(vals), sum(vals) / len(vals), max(vals), chip, lo, hi,
        sum(1 for v in vals if v < lo), sum(1 for v in vals if v > hi), grad, ngrad, nfill))
out.close()
print(open(out.name).read())
