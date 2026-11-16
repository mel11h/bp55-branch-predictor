#!/bin/bash
# One-step setup for clock-gated runs: writes cg/lib/ (git-ignored) from the PDK.
#   - the three flow-corner Liberty files with the ICG cells completed (cg/patch_liberty.py), gzipped
#   - the cell LEF with ICG output ECK as USE SIGNAL (cg/patch_lef_icg_use.py; only needed for
#     an OpenROAD without upstream commit a55161a17c)
# The PDK files are never modified. The patched Liberty is checked against the sha256 values
# recorded in cg/patch_liberty.log; a mismatch means the PDK release differs from v1.10.103.
# usage: cg/setup.sh          then: source cg/env.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/.." && pwd)"
SC="$root/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR"
LIBD="$SC/liberty"; [ -d "$LIBD/liberty" ] && LIBD="$LIBD/liberty"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
python3 -I "$here/patch_liberty.py" --all "$LIBD" "$tmp" > "$tmp/log"
if diff <(grep sha256 "$here/patch_liberty.log" | sort) <(grep sha256 "$tmp/log" | sort) > "$tmp/d"; then
  echo "Liberty: 3 corners patched, sha256 as recorded in cg/patch_liberty.log"
else
  echo "Liberty: sha256 differs from cg/patch_liberty.log (different PDK release?):"; cat "$tmp/d"
  [ -n "$FORCE" ] || { echo "nothing written; set FORCE=1 to keep the result anyway"; exit 1; }
fi
mkdir -p "$here/lib"
for f in "$tmp"/*.lib; do gzip -9 -c "$f" > "$here/lib/$(basename "$f").gz"; done
python3 -I "$here/patch_lef_icg_use.py" "$SC/lef/ics55_LLSC_H7CR_ecos.lef" "$here/lib/ics55_LLSC_H7CR_ecos_icgsig.lef"
ls -la "$here/lib"
