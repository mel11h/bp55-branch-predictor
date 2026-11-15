#!/usr/bin/env python3
# Summarise bpsim CSV lines (stdin or files): per-config suite averages.
import sys, collections, math
H="cfg,bits,trace,instr,b0,b1,b2,b3,b4,b5,ctaken,dirwrong,m0,m1,m2,m3,m4,m5,i0,i1,i2,i3,i4,i5,phantom,ph2,takencf,hit0,slow".split(',')
def load(files):
    rows=[]
    for fn in files:
        for l in open(fn):
            p=l.strip().split(',')
            if len(p)!=len(H): continue
            d={h:(p[i] if i in (0,2) else int(p[i])) for i,h in enumerate(H)}
            d['mis']=sum(d['m%d'%i] for i in range(6)); d['idr']=sum(d['i%d'%i] for i in range(6))+d['ph2']
            d['mpki']=1000*d['mis']/d['instr']; d['dacc']=100*(1-d['dirwrong']/max(1,d['b0']))
            d['cmpki']=1000*d['dirwrong']/d['instr']
            d['pen']=(3*d['mis']+2*d['idr'])/d['instr']          # extra cycles per instr, 6-stage core
            d['cpi']=1+d['pen']
            rows.append(d)
    return rows
def summarise(rows):
    by=collections.OrderedDict()
    for r in rows: by.setdefault(r['cfg'],[]).append(r)
    out=[]
    for c,rs in by.items():
        n=len(rs)
        out.append(dict(cfg=c,bits=rs[0]['bits'],n=n,mpki=sum(r['mpki'] for r in rs)/n,cmpki=sum(r['cmpki'] for r in rs)/n,
            dacc=sum(r['dacc'] for r in rs)/n, idrpki=sum(1000*r['idr']/r['instr'] for r in rs)/n,
            cpi=sum(r['cpi'] for r in rs)/n, gcpi=math.exp(sum(math.log(r['cpi']) for r in rs)/n),
            hit0=100*sum(r['hit0'] for r in rs)/sum(r['takencf'] for r in rs)))
    return out
if __name__=="__main__":
    rows=load(sys.argv[1:])
    print(f"{'config':28s} {'bits':>6s} {'MPKI':>7s} {'condMPKI':>8s} {'dirAcc%':>8s} {'IDr/kI':>7s} {'0bub%':>6s} {'CPI':>6s}")
    for s in summarise(rows): print(f"{s['cfg']:28s} {s['bits']:6d} {s['mpki']:7.3f} {s['cmpki']:8.3f} {s['dacc']:8.2f} {s['idrpki']:7.2f} {s['hit0']:6.1f} {s['cpi']:6.4f}")
