#!/usr/bin/env python3
"""Build the DRC coverage table: one row per rule of the (TVF-expanded, preprocessed) Calibre
deck, with the status of its KLayout translation in icsprout55_drc.drc.

usage: make_coverage.py rules.tsv icsprout55_drc.drc > coverage.tsv
  rules.tsv comes from tools/deck_rules.py (name, -, primary layers, description).

status values
  translated          same geometric construct, validated by injected tests or by the library run
  approximated        implemented with a construct that differs from the SVRF one (reason given);
                      results are a superset or close approximation, never claimed exact
  precondition        only the precondition of the rule is checked (e.g. "any 45-degree edge");
                      0 results proves the rule cannot fire, >0 means the rule itself was NOT checked
  not translated      not implemented; the reason says whether it can fire on BP55 at all
"""
import re, sys

rules = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
deck = open(sys.argv[2]).read()
impl = set(re.findall(r'"([A-Za-z0-9_]+)"\s*,\s*"[^"]*"\)', deck))          # out(..., "NAME", "desc")
impl |= set(re.findall(r'(?:dens|glob|grad)\.call\("([A-Za-z0-9_]+)"', deck))
impl |= set(m.replace("#{tag}", "M%d" % n) for m in re.findall(r'"(#\{tag\}_[A-Za-z0-9_]+)"', deck) for n in range(2, 6))
impl |= set(m.replace("#{tag}", "MET1") for m in re.findall(r'"(#\{tag\}_D_[A-Za-z0-9_]+)"', deck))
impl |= set(m.replace("#{tag}", "V%d" % n) for m in re.findall(r'"(#\{tag\}_[A-Za-z0-9_]+)"', deck) for n in range(1, 5))

if 'SEC.include?("fill")' in deck:
    for t in ["M1DUM", "M2DUM", "M3DUM", "M4DUM", "M5DUM", "T4M2DUM"]:
        impl |= {t + x for x in ("_W_1", "_S_1", "_S_2", "_S_3", "_S_4", "_S_5", "_S_6", "_S_13", "_S_14")}
APPROX = {
    "W_1b": "WITH WIDTH > 12 implemented as opening (size -6/+6); flags portions, not whole polygons",
    "MET1_W_1": "max-width part (WITH WIDTH > 12) implemented as opening",
    "S_2": "wide-metal span edges found by opening at the width limit instead of DFM SPACE BY INT; PRL from projected edge pairs",
    "S_3": "as S_2",
    "S_5": "dense line-end: line ends = short edges without concave corner; side segment taken inside an sp-deep box behind the end",
    "V1_S_3": "NOT CONNECTED not modelled: same-net pairs are reported too (superset)",
    "S_3v": "NOT CONNECTED not modelled (superset)",
    "CT_S_2": "NOT CONNECTED not modelled (superset)",
    "NW1_S_2": "NOT CONNECTED not modelled (superset)",
    "T4M2_W_1": "max-width part as opening; INDALL/DEUPAD variants not modelled (layers absent)",
    "T4M2_S_2": "as Mn_S_2",
    "ACT_W_3a": "GATE simplified to PO AND AA; channel width from gate edges on PO boundary",
    "ACT_S_2": "ENCLOSE RECTANGLE Y 0.3 0.08 approximated by error-region bbox >= 0.3",
    "ACT_S_4": "U/O-shape detection (proc SHAPE) replaced by notch check < 0.18",
    "PO_S_2": "WITH WIDTH > 0.13 as opening, PARA ONLY via projection metric",
    "PO_S_9": "as Mn_S_5",
    "PO_EX_2": "L-shape corner exclusion (Z) not modelled; may over-report at poly bends",
    "PO_R_1": "CONVEX EDGE count test replaced by non-rectangular gate test",
    "NP_S_2": "NOT TOUCH EDGE exclusions approximated by dropping zero-distance pairs",
    "NP_S_3": "as NP_S_2", "PP_S_2": "as NP_S_2", "PP_S_3": "as NP_S_2",
    "NP_S_5": "GATE_W simplified (gate = PO AND AA)",
    "NP_EN_1": "COIN EDGE exclusions approximated by dropping zero-distance pairs",
    "NP_EN_2": "as NP_EN_1", "PP_EN_1": "as NP_EN_1", "PP_EN_2": "as NP_EN_1",
    "NP_EN_3": "POLYres/HPR terms dropped (layers absent); zero-distance pairs dropped",
    "PP_EN_3": "as NP_EN_3",
    "ACT_EN_1": "zero-distance pairs dropped; NW1res term dropped (layer absent)",
    "ACT_EN_2": "zero-distance pairs dropped",
    "PO_EX_1": "zero-distance pairs dropped",
    "CT_S_4": "GATE_core simplified to PO interacting PO AND AA (DG/TG absent)",
    "CT_S_6": "only the 'NP/PP boundary through CT' part; the 0.06 enclosure part is not translated",
    "LU_S_2_NTAP": "SIZE ... INSIDE OF NW STEP 0.38 BEVEL 4 approximated by 35 x 1 um grow steps inside the well (Manhattan growth)",
    "LU_S_2_PTAP": "as LU_S_2_NTAP",
    "D_3": "gradient between edge-adjacent 100 um windows (non-overlapping, BACKUP at the edge); Calibre GRADIENT window pairing may differ",
    "D_1": "window placement follows WINDOW/STEP/BACKUP; INSIDE OF LAYER regions are the whole extent (GRID/SRINGBLK/INDALL absent)",
    "T4V2_EN_2_EN_3": "RECTANGLE ENC via per-side strips (exact for rectangular cuts)",
}
PRECOND = {"W_2v": 1}

def status(name, layers, desc):
    if name in impl:
        if name in APPROX and not name.startswith(("S_", "W_", "D_")):
            return "approximated", APPROX[name]
        if re.match(r"^(MET1|M[2-5])_W_1b?$", name) and (name.endswith("W_1b") or name == "MET1_W_1"):
            return "approximated", APPROX["W_1b"] + "; min-width part is exact"
        if re.match(r"^(MET1|M[2-5])_S_[23]$", name): return "approximated", APPROX["S_2"]
        if re.match(r"^(MET1|M[2-5])_S_5$", name): return "approximated", APPROX["S_5"]
        if re.search(r"_D_3$", name): return "approximated", APPROX["D_3"]
        if re.search(r"_D_[14]", name): return "translated", "WINDOW/STEP/BACKUP windows as in the deck; INSIDE OF LAYER region = whole extent (exclusion markers absent); global density = layer area / extent"
        if re.search(r"^V\d_S_3$", name): return "approximated", APPROX["S_3v"]
        if name in ("ACT_W_2", "PO_W_3", "PO_S_16", "RV_W_1", "T4V2_R_3", "T4V2_W_2") or re.search(r"^V\d_R_[35]$|^CT_R_3$", name):
            return "precondition", "only the rule's precondition is checked (45-degree edges / small holes / large PO / RV present)"
        return "translated", ("same construct; enclosure by per-side strips (exact for rectangular cuts)" if "_EN_" in name else "same construct")
    if name in ("ACT_S_3", "PO_S_6"):
        return "precondition", "needs 45-degree AA/PO; covered by the 45-degree precondition output of ACT_W_2 / PO_W_3"
    if name in ("PP_R_3", "CT_R_2", "PO_S_12"):
        return "not translated", "needs SAB (71/1), absent from the BP55 layout and the library GDS"
    if name in ("ACT_S_7", "NW1_S_3", "NW1_S_4"):
        return "not translated", "needs DNW or DGOX/TGOX wells, absent from the BP55 layout and the library GDS"
    if name.startswith("PSUB_"):
        return "not translated", "needs PSUB (261/12) polygons; the library carries only text labels on 261/12, no polygons"
    L = set(layers.split(",")) if layers else set()
    absent = {"DNWi", "NVT1", "PVT1", "NVT3", "PVT3", "ULLD", "DGOX", "TGOX", "SABi", "HRPi", "PSUBi", "ESD1",
              "T4V2i", "T4V2bar", "T4M2o", "RV", "RDLi", "CBi", "COVER", "EFUSEALL", "FUSEALL", "FUTR", "MOMTER", "ACTres",
              "POLYres", "NW1res", "MET1mom", "MET2mom", "MET3mom", "MET4mom", "MET5mom", "DEUPADi", "LDMOS", "VARAM", "SRAMALL",
              "MET1sloti", "MET2sloti", "MET3sloti", "MET4sloti", "MET5sloti"}
    pre = name.split("_")[0]
    if pre in ("DNW", "NVT1", "PVT1", "NVT3", "PVT3", "ULLD", "DG", "TG", "SAB", "HRP", "PSUB", "ESD", "ESDN", "ESDP", "AAres",
               "NWresAA", "NWresSTI", "POLYres", "EFU", "MOM", "CB", "RV", "RDL", "COVER", "SL"):
        return "not translated", "rule needs layer family %s, absent from the BP55 layout and the library GDS (layer inventory)" % pre
    if "DUM" in pre and pre in ("M6DUM", "M7DUM", "M8DUM"):
        return "not translated", "metal level not in the 1P6M stack (total_metal 6 = M1..M5 + T4M2)"
    if "DUM" in pre and re.search(r"_S_(9|10|11|12|15)$", name):
        return "not translated", "dummy spacing to FUSE/MIM/LOGO/INDALL/DMYBLK markers; those layers are absent"
    if "DUM" in pre and re.search(r"_S_7$", name):
        return "not translated", "dummy wide-metal run-length spacing construct (EXPAND EDGE chain) not translated"
    if "DUM" in pre and re.search(r"_S_8$", name):
        return "not translated", "dummy to 45-degree metal; 45-degree metal exists only inside library cells on M1"
    if "DUM" in pre:
        return "not translated", "dummy/fill rule (MnDUM/AADUM/PODUM datatype 2 shapes); no dummy polygons in the unfilled layout; becomes relevant with fill"
    if pre in ("SRCK", "CHIPEDGE", "DEUPAD"):
        return "not translated", "chip-level rule (seal ring / chip border / pad); not applicable to a block"
    if name.startswith("LU_"):
        return "not translated", "latch-up rule for devices connected to I/O pads; the block has no pads"
    if re.search(r"_W_3$", name) and pre.startswith(("M", "MET")):
        return "not translated", "needs a non-metal region > 2,000,000 um2; the whole block is 185,310 um2, so it cannot fire"
    if re.search(r"_D_2$", name):
        return "not translated", "density inside dummy-block (dmblk, datatype 3) regions; no dummy-block shapes present"
    if name in ("DGR_3", "skew_edge_check"):
        return "not translated", "off-angle edge check over all drawn layers; partially covered by the 45-degree checks"
    if any(x in L for x in ("DGOX", "TGOX")) and re.search(r"_(W_3b|S_1a|S_6|EN_2a|W_2b|W_2d|S_5|S_12)$", name):
        return "not translated", "1.8/2.5/3.3 V (DGOX/TGOX) variant; those layers are absent"
    return "not translated", "construct not translated (%s)" % (desc[:80] if desc else "see deck")

def category(name):
    p = name.split("_")[0]
    if re.match(r"^(MET1|M[2-5])$", p): return "BEOL metal" + (" density" if "_D_" in name else "")
    if re.match(r"^V[1-4]$", p): return "BEOL via"
    if p in ("T4V2", "T4M2", "RV", "RDL", "CB", "COVER"): return "BEOL top/pad" + (" density" if "_D_" in name else "")
    if p == "CT": return "contact"
    if "DUM" in p: return "dummy/fill"
    if p in ("LU",): return "latch-up"
    if p in ("SRCK", "CHIPEDGE", "DEUPAD", "SL"): return "chip-level"
    if "_D_" in name: return "FEOL density"
    if p in ("ESD", "ESDN", "ESDP", "EFU", "MOM", "AAres", "NWresAA", "NWresSTI", "POLYres", "HRP"): return "special device"
    return "FEOL"

print("rule\tcategory\tstatus\treason\tdeck_description")
for r in rules:
    name, _, layers, desc = (r + ["", "", ""])[:4]
    st, why = status(name, layers, desc)
    print("\t".join([name, category(name), st, why, desc[:200]]))
