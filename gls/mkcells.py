#!/usr/bin/env python3
"""Build a Yosys-readable (CXXRTL) copy of the ICsprout55 H7CR standard-cell Verilog models.

usage: mkcells.py <pdk cell .v> <out .v> [--suffix S] [--cells name,name,...] [--used netlist.v[.gz] ...]

The PDK models are written for event-driven simulators: sequential and mux cells are built from
user-defined primitives (UDP tables, `primitive ... endprimitive`), every cell has a specify block,
flops have a NOTIFIER reg for timing-check violations, and the ICG cells clock their latch from the
*delayed* signals dly_CK / dly_E that only the $setuphold timing check drives. Yosys reads none of
the UDPs, so this script makes the following mechanical changes and nothing else:

  1. every `primitive ... endprimitive` block is dropped and replaced by a behavioural module of the
     same name and port order (UDP_BEHAVIOUR below, written from the UDP tables; 2-state meaning,
     the X-pessimism rows of the tables have no 2-state counterpart);
  2. anonymous UDP instances (`udp_mux4 (Y, ...)`, legal for primitives, not for modules) get an
     instance name;
  3. specify ... endspecify blocks are removed (zero-delay functional simulation; the NOTIFIER regs
     are then never written, exactly as in a simulator that ignores timing checks);
  4. in cells whose specify block drives delayed signals (dly_<pin>) through $setuphold, those nets
     are tied to the undelayed pins (`assign dly_CK = CK;`), which is what a zero-delay simulator
     does with them;
  5. physical-only cells used by a routed netlist (FILLER*, FILLTAP: power pins only, no model in the
     PDK Verilog) become empty modules; with --stubs-only only those stubs are written (for Icarus,
     next to the unmodified PDK file); any other cell without a model is an error;
  6. optionally, only the cells used by the given netlists are kept, and every module name gets a
     suffix (used by the cell-equivalence test that simulates both libraries side by side).

The cell bodies themselves (gate primitives, buffers, assigns) are copied unchanged.
gls/cellcheck.sh proves, cell by cell in Icarus, that the result matches the original UDP models.
"""
import gzip
import re
import sys

UDP_BEHAVIOUR = {
    # out = flop; set_ wins over clr_ (table rows "? ? ? 0 : 1" and "? ? 0 1 : 0")
    "udp_dff": """module udp_dff (out, in, clk, clr_, set_, NOTIFIER);
  output reg out; input in, clk, clr_, set_, NOTIFIER;
  always @(posedge clk or negedge clr_ or negedge set_)
    if (!set_) out <= 1'b1; else if (!clr_) out <= 1'b0; else out <= in;
endmodule
""",
    # clr_ wins over set_ (rows "? ? 0 ? : 0" and "? ? 1 0 : 1")
    "udp_dff_rn_pre_sn": """module udp_dff_rn_pre_sn (out, in, clk, clr_, set_, NOTIFIER);
  output reg out; input in, clk, clr_, set_, NOTIFIER;
  always @(posedge clk or negedge clr_ or negedge set_)
    if (!clr_) out <= 1'b0; else if (!set_) out <= 1'b1; else out <= in;
endmodule
""",
    "udp_edff": """module udp_edff (out, in, clk, clr_, set_, en, NOTIFIER);
  output reg out; input in, clk, clr_, set_, en, NOTIFIER;
  always @(posedge clk or negedge clr_ or negedge set_)
    if (!set_) out <= 1'b1; else if (!clr_) out <= 1'b0; else if (en) out <= in;
endmodule
""",
    "udp_mux2": """module udp_mux2 (out, in0, in1, sel);
  output out; input in0, in1, sel;
  assign out = sel ? in1 : in0;
endmodule
""",
    "udp_mux": """module udp_mux (out, in, s_in, s_sel);
  output out; input in, s_in, s_sel;
  assign out = s_sel ? s_in : in;
endmodule
""",
    # rows: (sel_0, sel_1) = (0,0) in0, (1,0) in1, (0,1) in2, (1,1) in3
    "udp_mux4": """module udp_mux4 (out, in0, in1, in2, in3, sel_0, sel_1);
  output out; input in0, in1, in2, in3, sel_0, sel_1;
  assign out = sel_1 ? (sel_0 ? in3 : in2) : (sel_0 ? in1 : in0);
endmodule
""",
    # latch transparent while GB = 0; SB = 0 sets (wins), RB = 0 resets
    "ipicg_latchnsr": """module ipicg_latchnsr (Q, D, GB, SB, RB, NOTIFIER);
  output reg Q; input D, GB, SB, RB, NOTIFIER;
  always @*
    if (!SB) Q = 1'b1; else if (!RB) Q = 1'b0; else if (!GB) Q = D;
endmodule
""",
    "ipicg_latchsr": """module ipicg_latchsr (Q, D, G, SB, RB, NOTIFIER);
  output reg Q; input D, G, SB, RB, NOTIFIER;
  always @*
    if (!SB) Q = 1'b1; else if (!RB) Q = 1'b0; else if (G) Q = D;
endmodule
""",
    # latch transparent while hold = 0; set_ wins over clr_
    "udp_tlat": """module udp_tlat (out, in, hold, clr_, set_, NOTIFIER);
  output reg out; input in, hold, clr_, set_, NOTIFIER;
  always @*
    if (!set_) out = 1'b1; else if (!clr_) out = 1'b0; else if (!hold) out = in;
endmodule
""",
}


def opener(p):
    return gzip.open(p, "rt") if p.endswith(".gz") else open(p)


def main():
    a = sys.argv[1:]
    src, dst = a[0], a[1]
    suffix, cells, used = "", None, []
    i = 2
    while i < len(a):
        if a[i] == "--suffix":
            suffix = a[i + 1]; i += 2
        elif a[i] == "--cells":
            cells = set(a[i + 1].split(",")); i += 2
        elif a[i] in ("--icarus", "--stubs-only"):
            i += 1
        elif a[i] == "--used":
            i += 1
            while i < len(a) and not a[i].startswith("--"):
                used.append(a[i]); i += 1
        else:
            sys.exit("bad argument " + a[i])
    text = open(src).read()
    if "--icarus" in a:
        # Icarus copy: the PDK file unchanged (UDPs, specify blocks, timing checks kept) except that the
        # delayed timing-check nets, which Icarus 12 never drives ("Timing checks are not supported and
        # delayed signal ... will not be driven"), are tied to their undelayed pins (change 4 only).
        n = [0]
        def fix(m):
            body = m.group(0)
            pins = set(w.strip() for p in re.findall(r"\b(?:input|output)\s+([\w\s,]+);", body) for w in p.split(","))
            for d in sorted(set(re.findall(r"\bdly_(\w+)\b", body))):
                if d in pins:
                    body = re.sub(r"^endmodule", "assign dly_%s = %s;\nendmodule" % (d, d), body, count=1, flags=re.M)
                    n[0] += 1
            return body
        text = re.sub(r"^module\s+(\w+)\b.*?^endmodule[^\n]*", fix, text, flags=re.S | re.M)
        open(dst, "w").write(text)
        sys.stderr.write("mkcells --icarus: delayed nets tied: %d\n" % n[0])
        return
    # drop UDP definitions
    prims = set(re.findall(r"^\s*primitive\s+(\w+)", text, re.M))
    text = re.sub(r"^\s*primitive\b.*?endprimitive[^\n]*", "", text, flags=re.S | re.M)
    mods = {}
    for m in re.finditer(r"^module\s+(\w+)\b.*?^endmodule[^\n]*", text, re.S | re.M):
        mods[m.group(1)] = m.group(0)
    phys = set()
    if used:
        cells = set()
        for p in used:
            with opener(p) as f:
                for line in f:
                    t = line.split(None, 2)
                    if len(t) >= 2 and re.match(r"^[A-Z][A-Z0-9]*H7R$", t[0]):
                        if t[0] in mods:
                            cells.add(t[0])
                        elif re.match(r"^(FILLER\d+|FILLTAP)H7R$", t[0]):
                            phys.add(t[0])  # physical-only cell (power pins only in the LEF), no Verilog model
                        else:
                            cells.add(t[0])  # reported as missing below
    if cells is None:
        cells = set(mods)
    missing = sorted(c for c in cells if c not in mods)
    if missing:
        sys.exit("cells not in the PDK model file: " + " ".join(missing))
    out, need_udp, stats = [], set(), {"anon": 0, "dly": 0}
    for name in sorted(cells):
        body = mods[name]
        body = re.sub(r"\bspecify\b.*?\bendspecify\b", "", body, flags=re.S)
        def anon(m):
            stats["anon"] += 1
            return "%s%s u_anon%d (" % (m.group(1), m.group(2), stats["anon"])
        body = re.sub(r"^(\s*)(udp_\w+|ipicg_\w+)\s*\(", anon, body, flags=re.M)
        for u in prims:
            if re.search(r"^\s*%s\b" % u, body, re.M):
                need_udp.add(u)
        # delayed timing-check signals -> undelayed pins
        ports = set(re.findall(r"\b(?:input|output)\s+([\w\s,]+);", body))
        pins = set(w.strip() for p in ports for w in p.split(","))
        for d in sorted(set(re.findall(r"\bdly_(\w+)\b", body))):
            if d in pins:
                body = body.replace("endmodule", "assign dly_%s = %s;\nendmodule" % (d, d), 1)
                stats["dly"] += 1
        if suffix:
            body = re.sub(r"^module\s+%s\b" % name, "module %s%s" % (name, suffix), body, flags=re.M)
            for u in prims:
                body = re.sub(r"^(\s*)%s\b" % u, r"\g<1>%s%s" % (u, suffix), body, flags=re.M)
        out.append("`timescale 1ns/1ps\n" + body + "\n")
    for u in sorted(need_udp):
        if u not in UDP_BEHAVIOUR:
            sys.exit("no behavioural model for UDP " + u)
        b = UDP_BEHAVIOUR[u]
        if suffix:
            b = b.replace("module %s " % u, "module %s%s " % (u, suffix), 1)
        out.append("`timescale 1ns/1ps\n" + b)
    for c in sorted(phys):
        out.append("// physical-only cell, no signal pins and no model in the PDK Verilog: empty stub\nmodule %s%s (); endmodule\n" % (c, suffix))
    if "--stubs-only" in a:
        out = [o for o in out if o.startswith("// physical-only")]
    with open(dst, "w") as f:
        f.write("// generated by gls/mkcells.py from the ICsprout55 H7CR cell models; do not edit\n")
        f.write("".join(out))
    sys.stderr.write("mkcells: %d cells, UDPs replaced: %s, anonymous instances named: %d, delayed nets tied: %d\n"
                     % (len(cells), ",".join(sorted(need_udp)), stats["anon"], stats["dly"]))


if __name__ == "__main__":
    main()
