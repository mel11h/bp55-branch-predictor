# netgen setup for BP55 LVS (ICsprout55 core MOS only)
foreach dev {nm1p2_svt_lp pm1p2_svt_lp} {
  foreach c {1 2} {
    permute "-circuit$c $dev" drain source
    property "-circuit$c $dev" parallel enable
    property "-circuit$c $dev" series disable
    property "-circuit$c $dev" tolerance {w 0.01} {l 0.01}
    property "-circuit$c $dev" delete as ad ps pd nrd nrs
  }
}
