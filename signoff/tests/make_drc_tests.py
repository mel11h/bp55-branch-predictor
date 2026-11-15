# KLayout batch script: build a small GDS with deliberately injected DRC violations, one per
# test cell, plus legal "control" structures that must stay clean. The expected outcome per
# test is written next to the GDS as a TSV (test, rule, expect>0 or 0, x0, y0, x1, y1).
# usage: klayout -b -r make_drc_tests.py -rd out=tests.gds
import pya
ly = pya.Layout(); ly.dbu = 0.001
top = ly.create_cell("DRC_TESTS")
L = lambda l, d=1: ly.layer(l, d)
M1, M2, M3, M4, M5 = L(81), L(82), L(83), L(84), L(85)
V1, V4 = L(91), L(94)
AA, NW, PO, CT, NP, PP = L(2), L(9), L(41), L(72), L(52), L(53)
tests = []
slot = [0]
def region():
    x = (slot[0] % 6) * 20.0; y = (slot[0] // 6) * 20.0; slot[0] += 1
    return x, y
def box(layer, x0, y0, x1, y1):
    top.shapes(layer).insert(pya.DBox(x0, y0, x1, y1))
def test(name, rule, expect, build):
    x, y = region()
    build(x, y)
    tests.append((name, rule, expect, x - 1, y - 1, x + 19, y + 19))
def via_stack(x, y, v, lo, hi, el, er, eb, et, hl, hr, hb, ht):
    box(v, x, y, x + 0.09, y + 0.09)
    box(lo, x - el, y - eb, x + 0.09 + er, y + 0.09 + et)
    box(hi, x - hl, y - hb, x + 0.09 + hr, y + 0.09 + ht)

test("narrow_m2", "M2_W_1a", 1, lambda x, y: box(M2, x, y, x + 5, y + 0.08))
test("legal_m2", "M2_W_1a", 0, lambda x, y: box(M2, x, y, x + 5, y + 0.10))
test("space_m2", "M2_S_1", 1, lambda x, y: (box(M2, x, y, x + 5, y + 0.1), box(M2, x, y + 0.18, x + 5, y + 0.28)))
test("space_m2_legal", "M2_S_1", 0, lambda x, y: (box(M2, x, y, x + 5, y + 0.1), box(M2, x, y + 0.2, x + 5, y + 0.3)))
test("area_m2", "M2_A_1", 1, lambda x, y: box(M2, x, y, x + 0.3, y + 0.1))
test("hole_m2", "M2_A_2", 1, lambda x, y: (box(M2, x, y, x + 0.7, y + 0.2), box(M2, x, y + 0.5, x + 0.7, y + 0.7),
                                           box(M2, x, y, x + 0.2, y + 0.7), box(M2, x + 0.5, y, x + 0.7, y + 0.7)))
test("hole_m2_legal", "M2_A_2", 0, lambda x, y: (box(M2, x, y, x + 1, y + 0.2), box(M2, x, y + 0.5, x + 1, y + 0.7),
                                           box(M2, x, y, x + 0.2, y + 0.7), box(M2, x + 0.8, y, x + 1, y + 0.7)))
test("via1_m1enc", "V1_EN_2a_2b_2c", 1, lambda x, y: via_stack(x, y, V1, M1, M2, .02, .02, .02, .02, .04, .04, .005, .005))
test("via1_legal", "V1_EN_2a_2b_2c", 0, lambda x, y: via_stack(x, y, V1, M1, M2, .04, .04, 0, 0, .04, .04, .005, .005))
test("via1_legal_b", "V1_EN_5a_5b", 0, lambda x, y: via_stack(x, y, V1, M1, M2, .04, .04, 0, 0, .04, .04, .005, .005))
test("via1_m2enc0", "V1_EN_5a_5b", 1, lambda x, y: via_stack(x, y, V1, M1, M2, .04, .04, 0, 0, 0, .04, .02, .02))
test("via1_m2corner", "V1_EN_5a_5b", 1, lambda x, y: via_stack(x, y, V1, M1, M2, .04, .04, 0, 0, .01, .04, .01, .04))
test("via1_size", "V1_W_1", 1, lambda x, y: (box(V1, x, y, x + 0.1, y + 0.1), box(M1, x - .04, y - .04, x + .14, y + .14), box(M2, x - .04, y - .04, x + .14, y + .14)))
test("via1_space", "V1_S_1", 1, lambda x, y: (via_stack(x, y, V1, M1, M2, .04, .04, .04, .04, .04, .04, .04, .04),
                                              via_stack(x + 0.19, y, V1, M1, M2, .04, .04, .04, .04, .04, .04, .04, .04)))
test("via4_m5enc", "V4_EN_5a_5b", 1, lambda x, y: via_stack(x, y, V4, M4, M5, .04, .04, 0, 0, .01, .01, .01, .01))
test("wide_m3", "M3_S_2", 1, lambda x, y: (box(M3, x, y, x + 2, y + 0.5), box(M3, x, y + 0.62, x + 2, y + 0.72)))
test("wide_m3_ctrl", "M3_S_1", 0, lambda x, y: (box(M3, x, y, x + 2, y + 0.5), box(M3, x, y + 0.62, x + 2, y + 0.72)))
test("wide_m3_legal", "M3_S_2", 0, lambda x, y: (box(M3, x, y, x + 2, y + 0.5), box(M3, x, y + 0.66, x + 2, y + 0.76)))
# dense line end: M2 line (w 0.1) ending 0.11 before a crossing bar, with a parallel neighbour 0.11 away
test("lineend_m2", "M2_S_5", 1, lambda x, y: (box(M2, x, y, x + 2, y + 0.1), box(M2, x + 2.11, y - 1, x + 2.21, y + 1),
                                              box(M2, x, y + 0.21, x + 2.0, y + 0.31)))
test("lineend_m2_ctrl", "M2_S_5", 0, lambda x, y: (box(M2, x, y, x + 2, y + 0.1), box(M2, x + 2.11, y - 1, x + 2.21, y + 1),
                                                   box(M2, x, y + 0.25, x + 1.5, y + 0.35)))
test("ct_m1enc", "CT_EN_4a_4b_4c", 1, lambda x, y: (box(CT, x, y, x + .09, y + .09), box(M1, x - .01, y - .01, x + .1, y + .1),
                                                    box(AA, x - .1, y - .1, x + .2, y + .2)))
test("ct_legal", "CT_EN_4a_4b_4c", 0, lambda x, y: (box(CT, x, y, x + .09, y + .09), box(M1, x - .04, y, x + .13, y + .09),
                                                    box(AA, x - .1, y - .1, x + .2, y + .2)))
test("aa_space", "ACT_S_1", 1, lambda x, y: (box(AA, x, y, x + 1, y + 0.3), box(AA, x, y + 0.4, x + 1, y + 0.7)))
test("nw_width", "NW1_W_1", 1, lambda x, y: box(NW, x, y, x + 5, y + 0.4))
test("po_space", "PO_S_1", 1, lambda x, y: (box(PO, x, y, x + 0.06, y + 1), box(PO, x + 0.17, y, x + 0.23, y + 1)))
test("po_space_legal", "PO_S_1", 0, lambda x, y: (box(PO, x, y, x + 0.06, y + 1), box(PO, x + 0.18, y, x + 0.24, y + 1)))
test("m1_width", "MET1_W_1", 1, lambda x, y: box(M1, x, y, x + 3, y + 0.08))
M2D = L(82, 2)
test("fill_m2_near", "M2DUM_S_4", 1, lambda x, y: (box(M2, x, y, x + 5, y + 0.1), box(M2D, x, y + 1.1, x + 1, y + 2.1)))
test("fill_m2_size", "M2DUM_W_1", 1, lambda x, y: box(M2D, x, y, x + 0.5, y + 0.5))
test("fill_m2_legal", "M2DUM_S_6", 0, lambda x, y: (box(M2, x, y, x + 5, y + 0.1), box(M2D, x, y + 0.5, x + 0.22, y + 1.39)))
test("fill_m2_legal_w", "M2DUM_W_1", 0, lambda x, y: (box(M2, x, y, x + 5, y + 0.1), box(M2D, x, y + 0.5, x + 0.22, y + 1.39)))
ly.write(out)
with open(out.rsplit(".", 1)[0] + ".tsv", "w") as f:
    for t in tests:
        f.write("%s\t%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f\n" % t)
print("wrote", len(tests), "tests to", out)
