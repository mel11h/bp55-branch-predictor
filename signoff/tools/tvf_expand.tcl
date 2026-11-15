# Expand a Calibre TVF (Tcl-generated SVRF) deck into flat SVRF text, without Calibre.
# usage: tclsh tvf_expand.tcl deck.drc > deck.svrf
# Implements only the tvf:: commands the ICsprout55 decks use: VERBATIM, SETLAYER,
# OUTLAYER, RULECHECK, COMMENT, plus '@' comment lines and bare SVRF statements.
namespace eval tvf {
  proc emit {s} { puts $s }
  proc VERBATIM {txt} { emit $txt }
  proc SETLAYER {args} { emit [join $args " "] }
  proc OUTLAYER {args} { emit "  [join $args " "]" }
  proc COMMENT {args} { emit "  @ [join $args " "]" }
  proc RULECHECK {name body} {
    emit "$name \{"
    uplevel 1 $body
    emit "\}"
  }
  namespace export *
}
proc @ {args} { tvf::emit "  @ [join $args " "]" }
# bare SVRF lines inside Tcl context (e.g. LAYER, CONNECT, GROUP): echo them
rename unknown _tcl_unknown
proc unknown {args} {
  set w [lindex $args 0]
  if {[regexp {^[A-Z]} $w] || [regexp {^[a-z0-9_]+$} $w]} { tvf::emit [join $args " "]; return }
  uplevel 1 [list _tcl_unknown {*}$args]
}
set f [open [lindex $argv 0]]; set src [read $f]; close $f
regsub {^#!\s*tvf[^\n]*\n} $src "" src
eval $src
