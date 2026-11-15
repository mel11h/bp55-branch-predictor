import os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..') + '/'
import sys, collections
sys.path.insert(0, ROOT+'sim')
from summ import load
R=ROOT+'results/'
by=collections.defaultdict(dict)
for r in load([R+'final.csv']): by[r['cfg']][r['trace']]=r
P=list(by['BP55'])
for abl in ('BP55_noITC','BP55_noRAS'):
    d=sorted([(round(by[abl][p]['mpki']-by['BP55'][p]['mpki'],2),p) for p in P],reverse=True)
    tot=sum(x for x,_ in d); print(abl,'mean delta',round(tot/21,3),'top',d[:4])
    ex=[p for p in P if p not in('interp','recurse')]
    print('  without interp/recurse: mean delta', round(sum(by[abl][p]['mpki']-by['BP55'][p]['mpki'] for p in ex)/len(ex),3))
ex=[p for p in P if p not in('interp','recurse')]
for c in ('gshare_9k','BP55','BP55_128k','none','bimodal'):
    print(c,'mean MPKI w/o custom', round(sum(by[c][p]['mpki'] for p in ex)/19,3))
print('branches per prog (min):', min(sum(by['BP55'][p]['b%d'%i] for i in range(6)) for p in P))
print('cosim branch lookups', sum(min(300000,sum(by['BP55'][p]['b%d'%i] for i in range(6))) for p in P))
# gaps saturation check impossible w/o trace; instr per branch
for p in P:
    r=by['BP55'][p]; nb=sum(r['b%d'%i] for i in range(6))
print('noRAS m3 BP55 vs noRAS', sum(by['BP55'][p]['m3'] for p in P), sum(by['BP55_noRAS'][p]['m3'] for p in P))
