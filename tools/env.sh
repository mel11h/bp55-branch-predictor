# Source this file (bash): `source tools/env.sh`
# Puts the rootless RV32IM bare-metal toolchain (conda-forge clang/lld/llvm-tools
# 18.1.8, installed under tools/llvm18) on PATH and exports BP55_ROOT.
_bp55_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export BP55_ROOT="$(cd "$_bp55_here/.." && pwd)"
export BP55_LLVM="$_bp55_here/llvm18"
case ":$PATH:" in
  *":$BP55_LLVM/bin:"*) ;;
  *) export PATH="$BP55_LLVM/bin:$PATH" ;;
esac
# Clang's own freestanding headers (stdint.h, stddef.h, ...), used by bench/build.sh.
export BP55_CLANG_INC="$("$BP55_LLVM/bin/clang" -print-resource-dir)/include"
unset _bp55_here
