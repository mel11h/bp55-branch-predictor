#!/usr/bin/env python3
"""Flow workaround (not a PDK fix): ICG output pins ECK from USE CLOCK to USE SIGNAL in a LEF copy.

OpenROAD up to the fix in PR #10549 (commit a55161a17c, merged 2026-05-29; the installed
v2.0-17598 of Dec 2024 is older) has dbNet::getFirstOutput() skip every pin whose LEF USE is
CLOCK. The ICsprout55 LEF (correctly) declares the ICG outputs ECK as USE CLOCK, so every gated
clock net looks driverless to TritonCTS ("CTS-0122 Clock net ... is skipped for CTS because it is
not connected to any output instance pin") and no clock tree is built behind any ICG.
Declaring ECK as USE SIGNAL in a local copy makes getFirstOutput() find the ICG as the driver.
Nothing else in the flow reads the pin USE of a standard-cell output (clock nets get their CLOCK
type from CTS, timing comes from Liberty). With OpenROAD >= a55161a17c this copy is not needed.

usage: patch_lef_icg_use.py <upstream cell .lef> <out .lef>
"""
import re
import sys

src, dst = sys.argv[1:3]
out, macro, pin, n = [], None, None, 0
for line in open(src):
    m = re.match(r"^MACRO\s+(\S+)", line)
    if m:
        macro = m.group(1)
    p = re.match(r"^\s*PIN\s+(\S+)", line)
    if p:
        pin = p.group(1)
    if macro and re.match(r"^ICGN?X\w+H7R$", macro) and pin == "ECK" and re.match(r"^\s*USE\s+CLOCK\s*;", line):
        line = line.replace("CLOCK", "SIGNAL")
        n += 1
    out.append(line)
if n != 10:
    sys.exit(f"patch_lef_icg_use: changed {n} pins, expected 10")
open(dst, "w").writelines(out)
print(f"{dst}: ECK USE CLOCK -> USE SIGNAL in {n} ICG macros")
