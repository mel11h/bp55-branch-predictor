# Upper bound for fill: turn every dbFill shape of a filled database into wiring of the
# grounded special net VSS, which OpenRCX extracts as grounded metal (see
# rcx/validation/fill_openrcx_test.txt), and write a copy of the database.
# env: FILL_IN (.odb), FILL_OUT (.odb)
read_db $::env(FILL_IN)
set block [ord::get_db_block]
set vss [$block findNet VSS]
if {$vss eq "NULL"} { error "no VSS net" }
set sw [odb::dbSWire_create $vss ROUTED]
set n 0
foreach f [$block getFills] {
  set r [$f getRect]
  odb::dbSBox_create $sw [$f getTechLayer] [$r xMin] [$r yMin] [$r xMax] [$r yMax] FILLWIRE
  incr n
}
foreach f [$block getFills] { odb::dbFill_destroy $f }
puts "moved $n fill shapes to VSS; fills left [llength [$block getFills]]"
write_db $::env(FILL_OUT)
