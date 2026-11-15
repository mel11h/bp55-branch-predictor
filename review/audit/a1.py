import os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..') + '/'
import sys, math, collections
sys.path.insert(0, ROOT+'sim')
from summ import load, summarise
R=ROOT+'results/'
rows=load([R+'final.csv'])
by=collections.defaultdict(dict)
for r in rows: by[r['cfg']][r['trace']]=r
progs=list(by['BP55'].keys())
print('n progs',len(progs), progs)
print('total instr', sum(by['BP55'][p]['instr'] for p in progs))
print('total branches', sum(sum(by['BP55'][p]['b%d'%i] for i in range(6)) for p in progs))
def pooled(c):
    rs=by[c].values(); I=sum(r['instr'] for r in rs)
    return 1000*sum(r['mis'] for r in rs)/I, 100*(1-sum(r['dirwrong'] for r in rs)/sum(r['b0'] for r in rs)), 1+sum(3*r['mis']+2*r['idr'] for r in rs)/I
def cpiP(c,P):
    rs=by[c].values(); return sum(1+(P*r['mis']+2*r['idr'])/r['instr'] for r in rs)/len(rs)
def gm(c,k):
    rs=by[c].values(); return math.exp(sum(math.log(max(r[k],1e-9)) for r in rs)/len(rs))
for c in by:
    pm,pa,pc=pooled(c)
    print(f"{c:14s} pooledMPKI {pm:7.3f} pooledAcc {pa:6.2f} pooledCPI {pc:.4f} geoMPKI {gm(c,'mpki'):7.3f} CPI@12 {cpiP(c,12):.4f}")
print()
print('prog instr | none bim gsh9 BP55 128k | BP55-gsh  | itc m4,m5: BP55 gsh9 bim')
for p in progs:
    g=lambda c: by[c][p]['mpki']
    print(f"{p:16s} {by['BP55'][p]['instr']:10d} {g('none'):7.2f} {g('bimodal'):7.2f} {g('gshare_9k'):7.2f} {g('BP55'):7.2f} {g('BP55_128k'):7.2f} | {g('BP55')-g('gshare_9k'):+6.2f} | {by['BP55'][p]['m4']},{by['BP55'][p]['m5']} {by['gshare_9k'][p]['m4']},{by['gshare_9k'][p]['m5']} {by['bimodal'][p]['m4']},{by['bimodal'][p]['m5']} ph={by['BP55'][p]['phantom']}")
# wins count
w=sum(by['BP55'][p]['mpki']<by['gshare_9k'][p]['mpki'] for p in progs); print('BP55 beats gshare_9k on',w,'of',len(progs))
# leave-one-out mean differences
d=[by['gshare_9k'][p]['mpki']-by['BP55'][p]['mpki'] for p in progs]
print('mean diff',sum(d)/len(d),'contributions sorted',sorted([(round(x,2),p) for x,p in zip(d,progs)]))
