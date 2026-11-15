#!/usr/bin/env python3
# Merge the routed DEF with the standard-cell GDS into a final GDSII, then render PNG views.
import os, sys
try:
    import klayout.db as db          # pip install klayout
except ImportError:
    import pya as db                 # inside the KLayout application: klayout -b -r def2gds.py
# PDK location: $BP55_ROOT/pdk, else ../pdk next to this script (originally /home/user/bp55/pdk)
ROOT = os.environ.get("BP55_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PDK = os.path.join(ROOT, "pdk")
SC = PDK + "/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR"
# the GDS archive unpacks to <SC>/gds/*.gds (PDK Makefile layout); the original machine had <SC>/gds/gds
GDS = SC + "/gds/gds/ics55_LLSC_H7CR.gds"
if not os.path.exists(GDS):
    GDS = SC + "/gds/ics55_LLSC_H7CR.gds"
ROUTE = {"MET1": 81, "MET2": 82, "MET3": 83, "MET4": 84, "MET5": 85, "T4M2": 103, "RDL": 123}
CUT = {"VIA1": 91, "VIA2": 92, "VIA3": 93, "VIA4": 94, "T4V2": 113, "RV": 120}
with open("klayout.map", "w") as f:
    for n, g in ROUTE.items():
        # metal fill (DEF FILLS) goes to the foundry dummy datatype <layer>;2 (DRM 3.3.43, deck METxdmi)
        f.write(f"{n} NET,SPNET,PIN,LEFPIN,VIA {g} 1\n{n} FILL,FILLOPC {g} 2\n{n} LEFOBS {g} 1\nNAME {n}/PIN {g} 6\n")
    for n, g in CUT.items():
        f.write(f"{n} NET,SPNET,PIN,LEFPIN,VIA {g} 1\n")
    f.write("DIEAREA ALL 0 1\n")
opt = db.LoadLayoutOptions(); c = opt.lefdef_config
c.lef_files = [PDK + "/prtech/techLEF/N551P6M_ecos.lef", SC + "/lef/ics55_LLSC_H7CR_ecos.lef"]
c.read_lef_with_def = False
c.map_file = "klayout.map"
c.macro_resolution_mode = 2                      # take cell geometry from the foundry GDS, not from LEF
c.macro_layout_files = [GDS]
DEF_IN = os.environ.get("DEF_IN", "5_final.def"); GDS_OUT = os.environ.get("GDS_OUT", "bp55.gds")
ly = db.Layout(); ly.read(DEF_IN, opt)
top = ly.top_cell(); top.name = "bp55"
empty = [x.name for x in ly.each_cell() if x.is_empty() and x.name != "bp55"]
print("top:", top.name, "bbox um:", top.dbbox(), "cells:", ly.cells(), "empty(unresolved) cells:", len(empty), empty[:5])
ly.write(GDS_OUT)
print("layers:", sorted((li.layer, li.datatype) for li in ly.layer_infos()))
