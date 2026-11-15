#!/usr/bin/env python3
# Merge the routed DEF with the standard-cell GDS into a final GDSII, then render PNG views.
import sys, klayout.db as db, klayout.lay as lay
PDK = "/home/user/bp55/pdk"; SC = PDK + "/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR"
ROUTE = {"MET1": 81, "MET2": 82, "MET3": 83, "MET4": 84, "MET5": 85, "T4M2": 103, "RDL": 123}
CUT = {"VIA1": 91, "VIA2": 92, "VIA3": 93, "VIA4": 94, "T4V2": 113, "RV": 120}
with open("klayout.map", "w") as f:
    for n, g in ROUTE.items():
        f.write(f"{n} NET,SPNET,PIN,LEFPIN,VIA,FILL {g} 1\n{n} LEFOBS {g} 1\nNAME {n}/PIN {g} 6\n")
    for n, g in CUT.items():
        f.write(f"{n} NET,SPNET,PIN,LEFPIN,VIA {g} 1\n")
    f.write("DIEAREA ALL 0 1\n")
opt = db.LoadLayoutOptions(); c = opt.lefdef_config
c.lef_files = [PDK + "/prtech/techLEF/N551P6M_ecos.lef", SC + "/lef/ics55_LLSC_H7CR_ecos.lef"]
c.read_lef_with_def = False
c.map_file = "klayout.map"
c.macro_resolution_mode = 2                      # take cell geometry from the foundry GDS, not from LEF
c.macro_layout_files = [SC + "/gds/gds/ics55_LLSC_H7CR.gds"]
ly = db.Layout(); ly.read("5_final.def", opt)
top = ly.top_cell(); top.name = "bp55"
empty = [x.name for x in ly.each_cell() if x.is_empty() and x.name != "bp55"]
print("top:", top.name, "bbox um:", top.dbbox(), "cells:", ly.cells(), "empty(unresolved) cells:", len(empty), empty[:5])
ly.write("bp55.gds")
print("layers:", sorted((li.layer, li.datatype) for li in ly.layer_infos()))
