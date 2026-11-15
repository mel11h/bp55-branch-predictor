# KLayout batch script: per-layer inventory of a GDS (shapes/texts counted hierarchically,
# i.e. per cell definition, plus whether the layer appears in leaf cells or the top).
# usage: klayout -b -r layer_inventory.py -rd gds=FILE [-rd top=NAME]
import pya
ly = pya.Layout(); ly.read(gds)
tops = ly.top_cells()
top = ly.cell(globals()["top"]) if globals().get("top") else tops[0]
print("top cells:", len(tops))
print("file:", gds, "dbu:", ly.dbu, "top:", top.name, "cells:", ly.cells(), "bbox um:", top.dbbox())
print("%-8s %10s %10s %8s %8s" % ("L/D", "polys_def", "texts_def", "cells", "in_top"))
for li in ly.layer_indexes():
    info = ly.get_info(li)
    np = nt = nc = 0
    for c in ly.each_cell():
        k = 0
        for s in c.shapes(li).each():
            if s.is_text(): nt += 1
            else: np += 1
            k = 1
        nc += k
    print("%-8s %10d %10d %8d %8d" % ("%d/%d" % (info.layer, info.datatype), np, nt, nc, top.shapes(li).size()))
