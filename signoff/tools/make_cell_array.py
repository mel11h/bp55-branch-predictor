# KLayout batch script: place every top cell of a library GDS in one grid so a DRC/LVS deck can
# run on all of them in one pass. usage: klayout -b -r make_cell_array.py -rd lib=LIB.gds -rd out=OUT.gds [-rd cells=A,B]
import pya
ly = pya.Layout(); ly.read(lib)
names = [c.name for c in ly.top_cells()]
if globals().get("cells"):
    keep = set(cells.split(",")); names = [n for n in names if n in keep]
top = ly.create_cell("LIB_ARRAY")
x = y = 0; rowh = 0; dbu = ly.dbu; gap = int(5.0 / dbu); maxw = int(200.0 / dbu)
for n in sorted(names):
    c = ly.cell(n); b = c.bbox()
    if x + b.width() > maxw: x = 0; y += rowh + gap; rowh = 0
    top.insert(pya.CellInstArray(c.cell_index(), pya.Trans(x - b.left, y - b.bottom)))
    x += b.width() + gap; rowh = max(rowh, b.height())
for c in [c for c in ly.top_cells() if c.name not in names and c.name != "LIB_ARRAY"]:
    c.delete()
ly.write(out)
print("placed", len(names), "cells into LIB_ARRAY ->", out)
