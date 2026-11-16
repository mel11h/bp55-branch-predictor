#!/usr/bin/env python3
"""Derive gate-level versions of verif/tb_bp55_directed.sv and verif/tb_bp55_xprop.sv.

usage: mktb.py <netlist .v|.v.gz> <verif dir> <out dir>

The testbenches are unchanged except for their hierarchical references into the design, which
name RTL signals that a gate netlist represents differently:
  - dut.ghr, dut.thr, dut.rasp, dut.rstcnt   -> tb wires gl_* driven by the netlist nets of the
    same name (a vector in the synthesis netlist; ghr_0_ .. bit nets in a routed netlist);
  - dut.bim[i], dut.tctr0[i], ... in count_x_tables (indexed memories in the RTL) -> the loop is
    unrolled over the netlist nets bim[0] .. bim[63] etc.;
  - dut.bim[0][1:0]                          -> gl_bim0[1:0];
  - dut.ui_wr (an internal RTL wire, the ITC write enable, which synthesis does not keep): the
    check "correctly predicted far indirect does not rewrite the ITC" becomes "the whole ITC state
    (valid bits, tags, targets) is identical before and after the edge". This is weaker than the RTL
    check: a write of identical contents would pass.
The script fails if a pattern is not found or a netlist net is missing.
"""
import gzip
import re
import sys

net, vdir, odir = sys.argv[1:4]
txt = (gzip.open(net, "rt") if net.endswith(".gz") else open(net)).read()
decl = {}
for m in re.finditer(r"^\s*(?:wire|reg)\s+(?:\[(\d+):(\d+)\]\s+)?(\\\S+\s|\w+)\s*;", txt, re.M):
    hi, lo, name = m.group(1), m.group(2), m.group(3).strip()
    decl[name.lstrip("\\")] = (int(hi) if hi else None, int(lo) if lo else None, name)


# f_ckpt = {ras_top[31:2], rasp, thr, ghr} (rtl/bp55.sv); a routed netlist may name these flop nets
# after the output port only
PORT_ALIAS = {"ghr": "f_ckpt[27:0]", "thr": "f_ckpt[33:28]", "rasp": "f_ckpt[36:34]"}


def ident(n):
    return n + " " if n.startswith("\\") else n


def expr(key, width):
    """Verilog expression (MSB first) for RTL signal `key` (e.g. ghr, bim[3])."""
    if key in decl:
        hi, lo, n = decl[key]
        if hi is None and width != 1:
            sys.exit("net %s is scalar, expected %d bits" % (key, width))
        if hi is not None and hi - lo + 1 != width:
            sys.exit("net %s has %d bits, expected %d" % (key, hi - lo + 1, width))
        return "dut." + ident(n)
    if key in PORT_ALIAS and not any(k.startswith(key + "_") for k in decl):
        return "dut." + PORT_ALIAS[key]  # the flops drive the f_ckpt port directly; the net carries the port name
    bits = []
    for b in range(width - 1, -1, -1):
        k = "%s_%d_" % (key, b)
        if k not in decl:
            sys.exit("netlist has neither %s nor %s" % (key, k))
        bits.append("dut." + ident(decl[k][2]))
    return "{" + ", ".join(bits) + "}"


W = {"bim": 16, "tctr0": 3, "tctr1": 3, "tctr2": 3, "ttag0": 7, "ttag1": 7, "ttag2": 7, "ras": 30,
     "itc_tag": 8, "itc_tgt": 30}
wires = ["  // gate level: RTL signals referenced by the testbench, rebuilt from the netlist nets (gls/mktb.py)",
         "  wire [27:0] gl_ghr = %s;" % expr("ghr", 28),
         "  wire [5:0] gl_thr = %s;" % expr("thr", 6),
         "  wire [2:0] gl_rasp = %s;" % expr("rasp", 3),
         "  wire [10:0] gl_rstcnt = %s;" % expr("rstcnt", 11),
         "  wire [15:0] gl_bim0 = %s;" % expr("bim[0]", 16)]
itc = [expr("itc_v", 32)] + [expr("itc_tag[%d]" % i, 8) for i in range(32)] + [expr("itc_tgt[%d]" % i, 30) for i in range(32)]
wires.append("  wire [1247:0] gl_itc = {%s};" % ", ".join(itc))


def sub(s, old, new, count=None):
    n = s.count(old)
    if n == 0 or (count is not None and n != count):
        sys.exit("mktb: pattern %r found %d times" % (old, n))
    return s.replace(old, new)


for tbname in ("tb_bp55_directed.sv", "tb_bp55_xprop.sv"):
    s = open("%s/%s" % (vdir, tbname)).read()
    for k in ("ghr", "thr", "rasp", "rstcnt"):
        s = re.sub(r"\bdut\.%s\b" % k, "gl_" + k, s)
    if "xprop" in tbname:
        s = sub(s, "dut.bim[0][1:0]", "gl_bim0[1:0]", 1)
        m = re.search(r"  task automatic count_x_tables\(\);.*?endtask\n", s, re.S)
        if not m:
            sys.exit("mktb: count_x_tables not found")
        body = ["  task automatic count_x_tables();", "    xcnt = 0;"]
        for i in range(64):
            body.append("    if ($isunknown(%s)) xcnt++;" % expr("bim[%d]" % i, 16))
            body.append("    if ($isunknown(%s) || $isunknown(%s) || $isunknown(%s)) xcnt++;"
                        % tuple(expr("tctr%d[%d]" % (t, i), 3) for t in range(3)))
            body.append("    if ($isunknown(%s) || $isunknown(%s) || $isunknown(%s)) xcnt++;"
                        % tuple(expr("ttag%d[%d]" % (t, i), 7) for t in range(3)))
        for i in range(8):
            body.append("    if ($isunknown(%s)) xcnt++;" % expr("ras[%d]" % i, 30))
        body.append("    if ($isunknown({%s, %s, %s})) xcnt++;" % tuple(expr("tu%d" % t, 64) for t in range(3)))
        body.append("  endtask\n")
        s = s[:m.start()] + "\n".join(body) + s[m.end():]
    else:
        s = sub(s, '''    check("correctly predicted far indirect does not rewrite the ITC", dut.ui_wr == 1'b0);
    tick(); idle();''', '''    begin : gl_itc_check  // gate level: ui_wr is not a netlist net; compare the whole ITC state across the edge
      logic [1247:0] itc0; itc0 = gl_itc; tick(); idle();
      check("correctly predicted far indirect does not rewrite the ITC (gate level: ITC state unchanged)", gl_itc === itc0);
    end''', 1)
    s = sub(s, "  bp55 dut(.*);\n", "  bp55 dut(.*);\n" + "\n".join(wires) + "\n", 1)
    if "dut." in re.sub(r"bp55 dut\(\.\*\);", "", s.replace("\n".join(wires), "")).replace("count_x_tables", ""):
        left = [l for l in s.splitlines() if "dut." in l and "gl_" not in l and "$isunknown(" not in l and "bp55 dut" not in l]
        if left:
            sys.exit("mktb: unhandled hierarchical references:\n" + "\n".join(left))
    open("%s/gl_%s" % (odir, tbname), "w").write("// generated by gls/mktb.py from verif/%s; do not edit\n" % tbname + s)
print("mktb: wrote gl_tb_bp55_directed.sv, gl_tb_bp55_xprop.sv")
