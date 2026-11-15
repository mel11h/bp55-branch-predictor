"""How does OpenRCX (v2.0-17598) treat metal fill?

Three versions of one small layout, a 20 um MET3 signal wire with OPC-style fill bars
(pnr/flow/fill_rules.json sizes) beside it on MET3 and across it on MET2/MET4:
  nofill   : the wire alone
  fills    : the bars in the DEF FILLS section (what density_fill writes: dbFill objects)
  special  : the same bars as SPECIALNETS wiring of a grounded net (how fill would be seen
             if the extractor treated it as grounded metal)
Each is extracted with the typical rules; the wire's total capacitance is printed.

usage: python3 rcx/validation/fill_openrcx_test.py <work_dir>   (needs openroad, BP55_ROOT)
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
from compare_spef import read_spef  # noqa: E402

X0, X1, YC = 5000, 25000, 10000


def bars():
    r = []
    # MET3 bars 0.89 x 0.22 parallel to the wire, 0.30 from it, 0.25 fill-to-fill
    for side in (-1, 1):
        y0 = YC + side * (50 + 300)
        ylo, yhi = (y0, y0 + 220) if side > 0 else (y0 - 220, y0)
        x = X0
        while x + 890 <= X1:
            r.append(("MET3", x, ylo, x + 890, yhi))
            x += 890 + 250
    # MET2 / MET4 bars 0.22 x 0.89 across the wire, 0.47 pitch
    for lay in ("MET2", "MET4"):
        x = X0
        while x + 220 <= X1:
            r.append((lay, x, YC - 445, x + 220, YC + 445))
            x += 470
    return r


def write_def(path, mode):
    s = ["VERSION 5.8 ;", 'DIVIDERCHAR "/" ;', 'BUSBITCHARS "[]" ;', "DESIGN filltest ;",
         "UNITS DISTANCE MICRONS 1000 ;", "DIEAREA ( 0 0 ) ( 30000 20000 ) ;",
         "COMPONENTS 0 ;", "END COMPONENTS", "PINS 2 ;",
         f"    - t + NET t + DIRECTION OUTPUT + USE SIGNAL + PORT + LAYER MET3 ( -50 -50 ) ( 50 50 ) + PLACED ( {X0} {YC} ) N ;",
         f"    - t_BL + NET t + DIRECTION INPUT + USE SIGNAL + PORT + LAYER MET3 ( -50 -50 ) ( 50 50 ) + PLACED ( {X1} {YC} ) N ;",
         "END PINS"]
    b = bars()
    if mode == "special":
        s.append("SPECIALNETS 1 ;")
        s.append("    - VSS + USE GROUND")
        first = True
        for lay, xa, ya, xb, yb in b:
            kw = "+ ROUTED" if first else "NEW"
            first = False
            if xb - xa >= yb - ya:  # horizontal bar
                w = yb - ya
                y = (ya + yb) // 2
                s.append(f"      {kw} {lay} {w} + SHAPE STRIPE ( {xa} {y} ) ( {xb} * )")
            else:
                w = xb - xa
                x = (xa + xb) // 2
                s.append(f"      {kw} {lay} {w} + SHAPE STRIPE ( {x} {ya} ) ( * {yb} )")
        s.append("    ;")
        s.append("END SPECIALNETS")
    s.append("NETS 1 ;")
    s.append(f"    - t ( PIN t ) ( PIN t_BL ) + USE SIGNAL\n      + ROUTED MET3 ( {X0} {YC} 0 ) ( {X1} * 0 ) ;")
    s.append("END NETS")
    if mode == "fills":
        s.append(f"FILLS {len(b)} ;")
        for lay, xa, ya, xb, yb in b:
            s.append(f"    - LAYER {lay} + OPC RECT ( {xa} {ya} ) ( {xb} {yb} ) ;")
        s.append("END FILLS")
    s.append("END DESIGN")
    open(path, "w").write("\n".join(s) + "\n")


def main():
    wd = os.path.abspath(sys.argv[1])
    os.makedirs(wd, exist_ok=True)
    root = os.environ["BP55_ROOT"]
    out = ["OpenRCX typ rules, 20 um MET3 wire: total capacitance (fF) with fill in different forms"]
    res = {}
    for mode in ("nofill", "fills", "special"):
        d = os.path.join(wd, f"{mode}.def")
        write_def(d, mode)
        tcl = os.path.join(wd, f"{mode}.tcl")
        open(tcl, "w").write(
            f"read_lef {root}/pdk/prtech/techLEF/N551P6M_ecos.lef\nread_def {d}\n"
            "puts \"fills in block: [llength [[ord::get_db_block] getFills]]\"\n"
            "define_process_corner -ext_model_index 0 X\n"
            f"extract_parasitics -ext_model_file {root}/rcx/rules/bp55_typ.rules -max_res 0 -coupling_threshold 0.0 -cc_model 12 -context_depth 5\n"
            f"write_spef {wd}/{mode}.spef\n")
        log = os.path.join(wd, f"{mode}.log")
        subprocess.run(["openroad", "-threads", "1", "-no_init", "-exit", tcl], cwd=wd,
                       stdout=open(log, "w"), stderr=subprocess.STDOUT, check=True)
        nf = [l for l in open(log) if l.startswith("fills in block")]
        s = read_spef(os.path.join(wd, f"{mode}.spef"))["t"]
        res[mode] = s[0]
        out.append(f"  {mode:8s} total {s[0]:.3f} fF (ground {s[1]:.3f}, coupling {s[2]:.3f})  {nf[0].strip() if nf else ''}")
        print(out[-1], flush=True)
    out.append(f"  fill adds {100*(res['fills']/res['nofill']-1):+.1f} % as FILLS, {100*(res['special']/res['nofill']-1):+.1f} % as grounded special-net metal")
    print(out[-1])
    open(os.path.join(HERE, "fill_openrcx_test.txt"), "w").write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
