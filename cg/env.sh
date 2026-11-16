# source cg/env.sh  (after cg/setup.sh): makes pnr/flow/run.sh, finish.sh and sta.sh use the
# completed ICG Liberty and the LEF workaround. Timing of ungated designs is identical with
# either Liberty; power of gated designs is only right with this one.
_cg="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_cg/lib/ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib.gz" ] || echo "cg/lib is missing: run cg/setup.sh first"
export BP55_LIBDIR="$_cg/lib"
export BP55_CELL_LEF="$_cg/lib/ics55_LLSC_H7CR_ecos_icgsig.lef"
unset _cg
