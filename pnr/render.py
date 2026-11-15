import klayout.db as db, klayout.lay as lay
v = lay.LayoutView(); v.load_layout("bp55.gds", True); v.max_hier()
v.set_config("background-color", "#000000"); v.set_config("grid-visible", "false"); v.set_config("text-visible", "false")
COL = {(81,1):0x3987e5,(82,1):0xd95926,(83,1):0x199e70,(84,1):0xc98500,(85,1):0xd55181,(41,1):0xaa3333,(2,1):0x335533}
def style(show):
    it = v.begin_layers()
    while not it.at_end():
        p = it.current(); k = (p.source_layer, p.source_datatype)
        p.visible = k in show
        if k in COL: p.fill_color = p.frame_color = COL[k]; p.dither_pattern = 0 if k[0] >= 81 else 1; p.transparent = True
        it.next()
top = v.active_cellview().layout().top_cell().dbbox()
style({(81,1),(82,1),(83,1),(84,1),(85,1)}); v.zoom_fit(); v.save_image("layout_full.png", 2000, 2000)
style({(84,1),(85,1)}); v.zoom_fit(); v.save_image("layout_pdn_m4m5.png", 1400, 1400)
style({(2,1),(41,1),(81,1),(82,1),(83,1)}); v.zoom_box(db.DBox(200, 200, 230, 222)); v.save_image("layout_zoom.png", 2000, 1470)
