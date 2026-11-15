#!/bin/bash
# Rootless install of the RV32IM bare-metal toolchain used by bench/build.sh:
# conda-forge clang 18.1.8 + lld 18.1.8 + llvm-tools 18.1.8 (llvm-objcopy) into tools/llvm18.
# The original flow used Debian/Ubuntu clang-18 + lld-18 (/usr/lib/llvm-18).
# Exact package builds installed on 2026-11-15 are listed in tools/toolchain-lock.txt;
# `conda create --file tools/toolchain-lock.txt` reproduces them bit for bit.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
CONDA=${CONDA:-$HOME/miniconda3/bin/conda}
export CONDA_PKGS_DIRS=$here/conda-pkgs   # keep the download cache inside tools/, removed below
if [ "${1:-}" = "--lock" ]; then
  "$CONDA" create -y -p "$here/llvm18" --file "$here/toolchain-lock.txt"
else
  "$CONDA" create -y -p "$here/llvm18" --override-channels -c conda-forge clang=18.1.8 lld=18.1.8 llvm-tools=18.1.8
fi
rm -rf "$CONDA_PKGS_DIRS"
"$here/llvm18/bin/clang" --version | head -1
