# Geometric checks of metal fill in a merged GDS against the ICsprout55 dummy-metal rules
# (DRM V1.1.9 section 3.3.43.4 METndm-*, 3.3.43.6 T4Mndm-*). Drawn metal is <layer>;1,
# fill is <layer>;2 (deck: MET1o / MET1dmi ...).
#
# run:  klayout -b -r fill_check.py -rd gds=<filled.gds> -rd out=<report.txt>
import pya

UM = 1000  # dbu per um is read from the layout; this is only the fallback
# per layer: list of (allowed size w x h in um, fill-to-fill space, fill-to-metal space, rule ids)
ONEX = [((1.0, 1.0), 0.30, 3.0, "METndm-W.1/S.3/S.4"),
        ((0.22, 0.89), 0.25, 0.30, "METndm-W.1/S.5/S.6"),
        ((2.0, 2.0), 0.80, 10.0, "METndm-W.1/S.1/S.2")]
T4 = [((2.0, 2.0), 0.80, 10.0, "T4Mndm-W.1/S.1/S.2"),
      ((1.0, 1.0), 0.40, 0.60, "T4Mndm-W.1/S.3/S.4"),
      ((0.6, 1.2), 0.40, 0.60, "T4Mndm-W.1/S.5/S.6")]
LAYERS = [("MET1", 81, ONEX), ("MET2", 82, ONEX), ("MET3", 83, ONEX), ("MET4", 84, ONEX),
          ("MET5", 85, ONEX), ("T4M2", 103, T4)]
EDGE = 2.5      # METndm-S.13 / T4Mndm-S.13: fill to chip edge
WIDE = 1.5      # METndm-S.7: 0.6 um from metal wider than 1.5 um

ly = pya.Layout()
ly.read(gds)
top = ly.top_cell()
dbu = ly.dbu
u = lambda v: int(round(v / dbu))
o = open(out, "w")
o.write("fill check of %s\n" % gds.split("/")[-1])
o.write("%-5s %8s %8s %8s %10s %10s %10s %10s %8s %8s\n" % (
    "layer", "fills", "badsize", "overlap", "fill-metal", "fill-fill", "fill-edge", "wide-metal", "f-area%", "rule"))
total_bad = 0
for name, gl, rules in LAYERS:
    def reg(dt):
        li = ly.find_layer(gl, dt)
        return pya.Region(top.begin_shapes_rec(li)) if li is not None else pya.Region()
    drawn = reg(1)
    drawn.merge()
    fill = reg(2)
    nfill = fill.count()
    classes = {i: pya.Region() for i in range(len(rules))}
    bad = 0
    for p in fill.each():
        b = p.bbox()
        w, h = b.width() * dbu, b.height() * dbu
        hit = None
        for i, (sz, _, _, _) in enumerate(rules):
            if p.is_box() and (abs(w - sz[0]) < 1e-3 and abs(h - sz[1]) < 1e-3 or abs(w - sz[1]) < 1e-3 and abs(h - sz[0]) < 1e-3):
                hit = i
                break
        if hit is None:
            bad += 1
        else:
            classes[hit].insert(p)
    overlap = fill.interacting(drawn).count()  # overlapping or touching drawn metal
    fm = ff = 0
    for i, (sz, sff, sfm, _) in enumerate(rules):
        c = classes[i]
        if c.is_empty():
            continue
        fm += drawn.separation_check(c, u(sfm)).count()
        ff += c.space_check(u(sff)).count()
    # across classes: the smallest fill-to-fill rule
    allf = fill.dup()
    ff_any = allf.space_check(u(min(r[1] for r in rules))).count()
    bb = top.bbox()
    inner = pya.Region(bb.enlarged(-u(EDGE), -u(EDGE)))
    fe = (fill - inner).count()
    wide = drawn.sized(-u(WIDE / 2)).sized(u(WIDE / 2))
    wm = wide.separation_check(fill, u(0.6)).count() if not wide.is_empty() else 0
    farea = 100.0 * fill.area() / bb.area() if nfill else 0.0
    nb = bad + overlap + fm + ff + ff_any + fe + wm
    total_bad += nb
    o.write("%-5s %8d %8d %8d %10d %10d %10d %10d %8.2f   %s\n" % (
        name, nfill, bad, overlap, fm, ff + ff_any, fe, wm, farea, "; ".join(r[3] for r in rules)))
o.write("total violations: %d\n" % total_bad)
o.close()
print(open(out).read())
