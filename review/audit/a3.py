import os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..') + '/'
import sys, collections
sys.path.insert(0, ROOT+'sim')
from summ import load, summarise
R=ROOT+'results/'
rows=load([R+'final.csv'])
by=collections.defaultdict(list)
for r in rows: by[r['cfg']].append(r)
for P,K in [(12,2),(12,3),(12,4),(12,5),(12,11),(13,2),(14,2)]:
    f=lambda c: sum(1+(P*r['mis']+K*r['idr'])/r['instr'] for r in by[c])/21
    print(P,K, round(f('BP55'),4), round(f('gshare_9k'),4))
# grid CPI for candidate points
S={s['cfg']:s for s in summarise(load([R+'grid.csv']))}
for c in ['tage_b6_m8_i5_n3_t7','tage_b7_m9_i5_n3_t6','tage_b6_m9_i5_n3_t7','tage_b7_m9_i5_n4_t6','tage_b7_m8_i5_n3_t7']:
    s=S[c]; print(c,s['bits'],round(s['mpki'],3),round(s['cpi'],4))
print('best CPI tage <=8.2k', sorted([(round(s['cpi'],4),k,s['bits']) for k,s in S.items() if s['bits']<=8200])[:5])
print('best CPI any <=9.1k', sorted([(round(s['cpi'],4),k,s['bits']) for k,s in S.items() if s['bits']<=9100])[:5])
# idr incl ph2; hit0
b=by['BP55']; print('hit0 pooled', 100*sum(r['hit0'] for r in b)/sum(r['takencf'] for r in b))
# misprediction distribution
m=[sum(r['m%d'%i] for r in b) for i in range(6)]; t=sum(m); print('mis by type %',[round(100*x/t,1) for x in m])
# Kayip
for c in ['none','btb_only','bimodal','gshare_9k','BP55','BP55_16k','BP55_128k','BP55_noITC','BP55_noRAS','BP55_btb64','BP55_delay2']:
    print(c, round(1000*sum((3*r['mis']+2*r['idr'])/r['instr'] for r in by[c])/21,1))
