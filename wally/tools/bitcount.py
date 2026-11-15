#!/usr/bin/env python3
"""Storage bits of Wally's branch predictor for a derived configuration.

usage: bitcount.py <cvw dir> <cfg> [<cfg> ...]

Reads <cvw>/config/deriv/rv32im_<cfg>/config.vh and counts, from the register
and memory declarations of src/ifu/bpred/*.sv at commit 3617f2c:

  table bits     state that holds what the predictor has learned, the figure
                 comparable to BP55's 8132 bits (which counts its BTB, TAGE,
                 bimodal, indirect cache and RAS entries plus the RAS pointer):
                   direction  PHT 2^BPRED_SIZE x 2 (gshare.sv, twoBitPredictor.sv,
                              localbpbasic.sv ram2p1r1wbe PHT/BHT)
                   history    gshare GHRM (k bits, GHRReg); local LHRArray
                              2^BPRED_NUM_LHR x BPRED_SIZE
                   BTB        2^BTB_SIZE x (XLEN + 4): untagged, full target plus the
                              4 instruction-class bits (btb.sv ram2p1r1wbe memory); plus
                              BTB_TAG_BITS per entry with the wally/patches/0003 tag option
                   RAS        RAS_SIZE x XLEN entries + clog2(RAS_SIZE) pointer
                              (RASPredictor.sv memory, ptrreg)
  pipeline bits  flops inside src/ifu/bpred that carry per-instruction prediction
                 state down the pipeline (excluded from BP55's 8132 too); listed
                 for completeness, from the flopenr/flopenrc instances in each file.

The table sizes were checked against the elaborated design: in the Verilator model
of rv32im_gshare the bpred arrays are PHT RAM 1024 x 2, BTB RAM 1024 x 36, RAS
memory 512 bits, RAS ptrreg 4 bits, GHRReg 10 bits; for rv32im_local_iso PHT
1024 x 2, BTB 128 x 36, RAS 256 bits, ptrreg 3 bits, 64 LocalHistoryRegister
instances of 10 bits (verilator --cc, grep of the generated class headers).
"""
import math
import re
import sys
from pathlib import Path


def params(vh):
    p = {}
    for m in re.finditer(r"localparam\s+(?:[\w:]+\s+)?(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*([^;]+);", vh):
        v = m.group(2).strip()
        v2 = re.sub(r"^\d+'[dDbB]", "", v)
        p[m.group(1)] = int(v2) if v2.isdigit() else v
    m = re.search(r"^// harness defines:(.*)$", vh, re.M)
    for d in (m.group(1).split() if m else []):
        k, _, v = d.partition("=")
        p[k] = v or 1
    return p


def count(p):
    xl = p["XLEN"]
    t, pipe = {}, {}
    if not p["BPRED_SUPPORTED"]:
        typ = "none"
    else:
        typ = p["BPRED_TYPE"].split("::")[-1]
    k, m = p["BPRED_SIZE"], p["BPRED_NUM_LHR"]
    if typ in ("BP_GSHARE", "BP_GLOBAL"):
        t["PHT"] = 2 ** k * 2
        t["GHR"] = k
        pipe["gshare IndexW, BPDirD/E, NewBPDirM/W, PCSrcM"] = k + 9
    elif typ == "BP_TWOBIT":
        t["PHT"] = 2 ** k * 2
        pipe["twobit BPDirD/E, NewBPDirM"] = 6
    elif typ == "BP_LOCAL_BASIC":
        t["PHT"] = 2 ** k * 2
        t["LHR array"] = 2 ** m * k
        pipe["local BPDirD/E, NewBPDirM, PCSrcM, LHRF/D/E/M"] = 7 + 4 * k
    elif typ == "BP_STATIC":
        pipe["static PredTakenE"] = 1
    elif typ == "BP_BP55":
        # rtl/bp55.sv v2 state (see its header): BTB 128 x {v, tag 8, type 3, target 18}, bimodal
        # 512 x 2, TAGE 3 x 64 x {tag 7, ctr 3, u 1}, ITC 32 x {v, tag 8, target 30}, RAS 8 x 30 + pointer 3,
        # GHR 28, THR 6, use_alt 4, u-reset counter 11, clear sequencer 7
        t.update({"BTB": 128 * 30, "bimodal": 512 * 2, "TAGE": 3 * 64 * 11, "ITC": 32 * 39,
                  "RAS entries": 8 * 30, "RAS pointer": 3, "GHR+THR": 28 + 6, "use_alt+rstcnt+clear": 4 + 11 + 7})
        # wally/patches/0002-bpred-bp55.patch: MetaD/E 104, CkptD/E/M 67, TypeE 3; 5 HPM-only bits
        pipe["BP55 f_meta D+E (2 x 104), f_ckpt D+E+M (3 x 67), TypeE 3"] = 2 * 104 + 3 * 67 + 3
        pipe["BP55 counter sources at M (HPM only)"] = 5
    elif typ != "none":
        raise SystemExit(f"bitcount: unknown predictor type {typ}")
    if typ not in ("none", "BP_STATIC", "BP_BP55"):
        b = p["BTB_SIZE"]
        tag = int(p.get("BTB_TAG_BITS", 0))          # wally/patches/0003 option
        t["BTB"] = 2 ** b * (xl + 4 + tag)
        n = p["RAS_SIZE"]
        t["RAS entries"] = n * xl
        t["RAS pointer"] = math.ceil(math.log2(n))
        pipe["btb BPBTAD/E, PCW, IEUAdrW, BPBTAWrongM"] = 4 * xl + 1
        pipe["bpred PCLinkD"] = xl
        if p["ZIHPM_SUPPORTED"]:
            pipe["bpred RASPCD/E, BPDirWrongM, RASPredPCWrongM (HPM only)"] = 2 * xl + 2
        pipe["bpred PCSrcM"] = 1
    pipe["bpred/ifu BPWrongM"] = 1
    pipe["icpred class registers E/M/W, predicted class D, class-wrong E/M"] = 2 + 4 + 4 + 4 + 1 + 1
    return typ, t, pipe


def main():
    cvw = Path(sys.argv[1])
    for cfg in sys.argv[2:]:
        p = params((cvw / "config" / "deriv" / f"rv32im_{cfg}" / "config.vh").read_text())
        typ, t, pipe = count(p)
        tb, pb = sum(t.values()), sum(pipe.values())
        parts = ", ".join(f"{k} {v}" for k, v in t.items()) or "no tables"
        print(f"{cfg:<11} {typ:<15} table bits {tb:6d} ({parts}); pipeline bits {pb}")


if __name__ == "__main__":
    main()
