import sys
from pyosys import libyosys as ys
d=ys.Design()
for c in sys.argv[1].split(';'):
    c=c.strip()
    if c: ys.run_pass(c,d)
