# KLayout batch: list polygons (flattened within a cell) on given layers near a point.
# usage: klayout -b -r dump_near.py -rd gds=F -rd cell=C -rd x=.. -rd y=.. [-rd r=0.3] [-rd layers=72/1,81/1]
import pya
ly = pya.Layout(); ly.read(gds); c = ly.cell(cell)
X, Y, R = float(x), float(y), float(globals().get("r", "0.3"))
win = pya.DBox(X - R, Y - R, X + R, Y + R)
lays = globals().get("layers", "2/1,9/1,41/1,52/1,53/1,72/1,81/1,82/1,91/1")
for spec in lays.split(","):
    l, d = map(int, spec.split("/"))
    li = ly.find_layer(l, d)
    if li is None: continue
    reg = pya.Region(c.begin_shapes_rec_touching(li, win.to_itype(ly.dbu))); reg.merge()
    for p in reg.each():
        dp = p.to_dtype(ly.dbu)
        if dp.bbox().overlaps(win): print(spec, dp)
