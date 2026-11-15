#!/usr/bin/env python3
"""Derive a Wally configuration for the BP55 harness.

usage: mkconfig.py <cvw dir> <name> <base.cfg> <name.cfg>

Writes <cvw>/config/deriv/rv32im_<name>/config.vh from <cvw>/config/<BASE>/config.vh,
where BASE is given by a "base <config>" line in base.cfg, applying every
"PARAM value" line of base.cfg and then of <name>.cfg (later lines win). The
substitution is the one bin/derivgen.pl performs ("PARAM = ...;" -> "PARAM = value;"),
but a parameter that is not found is an error, not a warning. Lines starting with
'#' are comments. A line "unsupported <reason>" makes the configuration refuse to build.
A line "define NAME[=VALUE]" is a Verilog define for the build (wally.sh passes it as
+define+NAME[=VALUE]; wally/patches/0003 uses RAS_HINT_FIX and BTB_TAG_BITS); the defines are
recorded in a comment line of the derived config.vh, so they are part of the build stamp.
"""
import re
import sys
from pathlib import Path


def read_cfg(path):
    base, unsupported, params, defines = None, None, [], []
    for raw in Path(path).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key, _, val = line.partition(" ")
        val = val.strip()
        if key == "base":
            base = val
        elif key == "unsupported":
            unsupported = val
        elif key == "define":
            defines.append(val)
        else:
            params.append((key, val))
    return base, unsupported, params, defines


def main():
    cvw, name, basecfg, cfg = sys.argv[1:5]
    base, _, bparams, bdefs = read_cfg(basecfg)
    b2, unsupported, cparams, cdefs = read_cfg(cfg)
    if unsupported:
        sys.exit(f"mkconfig: configuration '{name}' is not buildable yet: {unsupported}")
    base = b2 or base
    text = (Path(cvw) / "config" / base / "config.vh").read_text()
    for param, value in bparams + cparams:
        pat = re.compile(r"\b" + re.escape(param) + r"\s*=\s*.*;")
        text, n = pat.subn(f"{param} = {value};", text)
        if n != 1:
            sys.exit(f"mkconfig: parameter {param} matched {n} times in {base}/config.vh")
    out = Path(cvw) / "config" / "deriv" / f"rv32im_{name}"
    out.mkdir(parents=True, exist_ok=True)
    header = f"// Config rv32im_{name} derived from {base} by bp55-branch-predictor/wally/tools/mkconfig.py\n"
    if bdefs + cdefs:
        header += f"// harness defines: {' '.join(bdefs + cdefs)}\n"
    new = header + text
    p = out / "config.vh"
    if not p.exists() or p.read_text() != new:  # keep the timestamp when unchanged
        p.write_text(new)
    print(f"rv32im_{name}")


if __name__ == "__main__":
    main()
