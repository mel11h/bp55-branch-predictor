# KLayout batch: antenna test layout. Cell ANT_TESTS holds three structures, each a single
# 0.06 x 0.30 um gate (gate area 0.018 um2) whose poly is contacted to M1 and, through VIA1,
# to an M2 plate:
#   bad    (x=0)   : M2 plate 1 x 120 um = 120 um2 -> M2/gate = 6667 > 5000, no diode -> AR_5_10_M2 must fire
#   good   (x=20)  : M2 plate 1 x 60 um  = 60 um2  -> ratio 3333 < 5000             -> must stay clean
#   diode  (x=40)  : like bad, plus an N+ diffusion on the same M1 net            -> must stay clean
# usage: klayout -b -r make_antenna_tests.py -rd out=ant.gds
import pya
ly = pya.Layout(); ly.dbu = 0.001
top = ly.create_cell("ANT_TESTS")
L = lambda l, d=1: ly.layer(l, d)
AA, PO, NP, CT, M1, V1, M2 = L(2), L(41), L(52), L(72), L(81), L(91), L(82)
def box(l, x0, y0, x1, y1): top.shapes(l).insert(pya.DBox(x0, y0, x1, y1))
def gate_net(x, plate_len, diode):
    box(AA, x, 0, x + 0.4, 0.3); box(NP, x - 0.2, -0.2, x + 0.6, 0.5)          # transistor active
    box(PO, x + 0.17, -0.2, x + 0.23, 0.9)                                     # gate poly, landing pad on top
    box(PO, x + 0.13, 0.6, x + 0.27, 0.9)
    box(CT, x + 0.155, 0.705, x + 0.245, 0.795)
    box(M1, x + 0.10, 0.70, x + 1.5, 0.80)
    box(V1, x + 1.3, 0.705, x + 1.39, 0.795)
    box(M2, x + 1.25, 0.66, x + 2.25, 0.66 + plate_len)
    if diode:
        box(AA, x + 0.9, 1.2, x + 1.2, 1.5); box(NP, x + 0.7, 1.0, x + 1.4, 1.7)
        box(CT, x + 1.005, 1.305, x + 1.095, 1.395); box(M1, x + 0.96, 0.70, x + 1.14, 1.44)
gate_net(0, 120, False); gate_net(20, 60, False); gate_net(40, 120, True)
ly.write(out)
print("wrote", out)
