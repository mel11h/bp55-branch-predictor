# KLayout batch: merge a routed DEF with the standard-cell GDS, like pnr/def2gds.py, but with
# the cell GDS variant that matches the LEF used for routing.
#
# Why: the flow routes against ics55_LLSC_H7CR_ecos.lef, whose signal pins are MET2 rectangles
# with a VIA1 down to the MET1 pin. Those MET2/VIA1 pin shapes exist only in
# ics55_LLSC_H7CR_M2.gds; ics55_LLSC_H7CR.gds (used by pnr/def2gds.py) has MET1 pins only, so a
# GDS merged from it has every routed pin connection ending on bare dielectric.
#
# usage: klayout -b -r def2gds_m2.py -rd def=5_final.def[.gz] -rd out=bp55_m2.gds[.gz]
#        [-rd cellgds=PATH] [-rd root=REPO]
import os, gzip, tempfile
import pya as db
ROOT = globals().get("root") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
PDK = os.path.join(ROOT, "pdk")
SC = PDK + "/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR"
GDS = globals().get("cellgds") or SC + "/gds/ics55_LLSC_H7CR_M2.gds"
ROUTE = {"MET1": 81, "MET2": 82, "MET3": 83, "MET4": 84, "MET5": 85, "T4M2": 103, "RDL": 123}
CUT = {"VIA1": 91, "VIA2": 92, "VIA3": 93, "VIA4": 94, "T4V2": 113, "RV": 120}
tmp = tempfile.mkdtemp()
mapf = os.path.join(tmp, "klayout.map")
with open(mapf, "w") as f:   # same map as pnr/def2gds.py (verified against the Calibre deck), fill on datatype 2
    for n, g in ROUTE.items():
        f.write(f"{n} NET,SPNET,PIN,LEFPIN,VIA {g} 1\n{n} FILL,FILLOPC {g} 2\n{n} LEFOBS {g} 1\nNAME {n}/PIN {g} 6\n")
    for n, g in CUT.items():
        f.write(f"{n} NET,SPNET,PIN,LEFPIN,VIA {g} 1\n")
    f.write("DIEAREA ALL 0 1\n")
d = def_ if "def_" in globals() else globals()["def"]
if d.endswith(".gz"):
    plain = os.path.join(tmp, "in.def")
    with gzip.open(d, "rb") as fi, open(plain, "wb") as fo:
        fo.write(fi.read())
    d = plain
opt = db.LoadLayoutOptions(); c = opt.lefdef_config
c.lef_files = [PDK + "/prtech/techLEF/N551P6M_ecos.lef", SC + "/lef/ics55_LLSC_H7CR_ecos.lef"]
c.read_lef_with_def = False
c.map_file = mapf
c.macro_resolution_mode = 2
c.macro_layout_files = [GDS]
ly = db.Layout(); ly.read(d, opt)
top = ly.top_cell(); top.name = "bp55"
empty = [x.name for x in ly.each_cell() if x.is_empty() and x.name != "bp55"]
print("cell GDS:", os.path.basename(GDS), "top bbox um:", top.dbbox(), "cells:", ly.cells(), "empty cells:", len(empty))
ly.write(out)
os.remove(mapf)
if os.path.exists(os.path.join(tmp, "in.def")): os.remove(os.path.join(tmp, "in.def"))
os.rmdir(tmp)
print("layers:", sorted((li.layer, li.datatype) for li in ly.layer_infos()))
