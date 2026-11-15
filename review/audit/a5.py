import os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..') + '/'
import sys, collections
sys.path.insert(0, ROOT+'sim')
from summ import load
R=ROOT+'results/'
by=collections.defaultdict(dict)
for r in load([R+'final.csv']): by[r['cfg']][r['trace']]=r
for p in ('xgboost','huffbench','depthconv','qrduino','recurse'):
    print(p,[ (c,round(by[c][p]['mpki'],2)) for c in ('gshare_9k','BP55','BP55_16k','BP55_32k','BP55_128k')])
g=load([R+'grid.csv']); print('grid phantom total', sum(r['phantom'] for r in g), 'ph2', sum(r['ph2'] for r in g))
e=load([R+'explore1.csv']+[R+'tune.csv']); print('explore/tune phantom', sum(r['phantom'] for r in e))
# instructions/branches identical across cfgs?
print('instr identical across final cfgs:', len(set((r['trace'],r['instr']) for r in load([R+'final.csv'])))==21)
# 'none' config: decode-redirect and nobtb checks
n=by['none']['coremark']; print('none coremark m0..5',[n['m%d'%i] for i in range(6)],'i0..5',[n['i%d'%i] for i in range(6)])
