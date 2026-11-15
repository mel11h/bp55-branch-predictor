import os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..') + '/'
import sys
sys.path.insert(0, ROOT+'sim')
from summ import load, summarise
R=ROOT+'results/'
S=summarise(load([R+'grid.csv']))
print(len(S),'configs; traces per cfg', set(s['n'] for s in S))
fam=lambda c: c.split('_')[0]
for f in ('bim','gsh','tage'):
    xs=sorted([s for s in S if fam(s['cfg'])==f], key=lambda s:s['bits'])
    # pareto front
    best=1e9; front=[]
    for s in xs:
        if s['mpki']<best: best=s['mpki']; front.append(s)
    print(f, 'pareto:', [(s['cfg'],s['bits'],round(s['mpki'],2)) for s in front])
# does the best tage at <= bits beat best gsh/bim at same bits for every gsh/bim point?
T=[s for s in S if fam(s['cfg'])=='tage']
bad=[]
for s in S:
    if fam(s['cfg'])=='tage': continue
    cand=[t['mpki'] for t in T if t['bits']<=s['bits']]
    if not cand or min(cand)>=s['mpki']: bad.append((s['cfg'],s['bits'],round(s['mpki'],2), round(min(cand),2) if cand else None))
print('non-tage points not dominated by a tage point at <= bits:', bad)
for s in S:
    if s['cfg'] in ('tage_b7_m9_i5_n3_t6',): print(s)
print(sorted([(round(s['mpki'],3),s['cfg'],s['bits']) for s in T if 7500<=s['bits']<=9000])[:10])
