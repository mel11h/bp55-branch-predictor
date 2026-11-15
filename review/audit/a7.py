import os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..') + '/'
import sys, collections
sys.path.insert(0, ROOT+'sim')
from summ import load
R=ROOT+'results/'
by=collections.defaultdict(dict); bits={}
for r in load([R+'grid.csv']): by[r['cfg']][r['trace']]=r; bits[r['cfg']]=r['bits']
P=sorted(next(iter(by.values())).keys())
def sel(fam,maxb,progs,key):
    c=[k for k in by if k.startswith(fam) and bits[k]<=maxb]
    return min(c,key=lambda k: sum(by[k][p][key] for p in progs))
for key in ('cpi','mpki'):
  for fam,maxb in (('tage',8200),('gsh',9100)):
    full=sel(fam,maxb,P,key); insample=sum(by[full][p]['mpki'] for p in P)/21
    loo=sum(by[sel(fam,maxb,[q for q in P if q!=p],key)][p]['mpki'] for p in P)/21
    chosen=collections.Counter(sel(fam,maxb,[q for q in P if q!=p],key) for p in P)
    print(key,fam,'full-sample pick',full,round(insample,3),'LOO MPKI',round(loo,3),dict(chosen))
for p in P:
    s=sel('tage',8200,[q for q in P if q!=p],'cpi')
    if s!='tage_b7_m9_i5_n3_t6': print('held out',p,'->',s, round(by[s][p]['mpki'],2),'vs',round(by['tage_b7_m9_i5_n3_t6'][p]['mpki'],2))
