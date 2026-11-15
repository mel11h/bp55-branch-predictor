import os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..') + '/'
import gzip, re, sys, collections
txt=gzip.open(ROOT+'pnr/5_final.v.gz','rt').read()
inst=re.compile(r'^\s*([A-Za-z0-9_]+)\s+(\\?\S+)\s*\((.*?)\);', re.S|re.M)
drv={}; cells={}
OUT={'Y','Q','Z','ECK','CO','S'}
for m in inst.finditer(txt):
    ct,name,body=m.groups()
    if ct in ('module','input','output','wire','assign'): continue
    pins=dict(re.findall(r'\.(\w+)\(([^()]*)\)',body))
    pins={k:v.strip() for k,v in pins.items()}
    cells[name]=(ct,pins)
    for k,v in pins.items():
        if k in OUT and v: drv[v]=name
print('cells',len(cells))
def back(net,depth=0,maxd=40):
    path=[]
    while depth<maxd:
        if net not in drv: path.append(('PORT/undriven',net)); break
        n=drv[net]; ct,p=cells[n]; path.append((ct,n))
        if 'DFF' in ct: break
        ins=[v for k,v in p.items() if k not in OUT and k not in ('VDD','VSS')]
        if len(ins)!=1:
            path.append(('multi-input', ins)); break
        net=ins[0]; depth+=1
    return path
for ep in sys.argv[1:]:
    ct,p=cells[ep]; print(ep,ct,'D=',p.get('D')); print('  ',back(p['D']))
# statistics: how many flop D pins are driven through chains of >=1 buffers/delay cells from a primary input?
inputs=set(re.findall(r'^\s*input\s+(?:\[[^\]]*\]\s*)?([^;]+);',txt,re.M))
ins=set()
for l in inputs:
    for x in l.split(','): ins.add(x.strip())
print('input decls sample', list(ins)[:10])
cnt=collections.Counter()
for n,(ct,p) in cells.items():
    if 'DFF' in ct:
        path=back(p['D'])
        nbuf=sum(1 for c,_ in path if c.startswith(('BUF','DLY','DEL')))
        cnt[(nbuf>0, path[-1][0])]+=1
print(cnt.most_common(12))

def chain(net):
    out=[]
    for _ in range(30):
        if net not in drv: out.append('<'+net+'>'); break
        n=drv[net]; ct,p=cells[n]; out.append(ct)
        ins=[v for k,v in p.items() if k not in OUT]
        if len(ins)!=1: out.append('(%d-input)'%len(ins)); break
        net=ins[0]
    return out
for net in ['net8273','net7108','net8124','net6950','_21580_']:
    print(net, chain(net))
# Count buffer types used as hold buffers: cells named hold*
hc=collections.Counter(ct for n,(ct,p) in cells.items() if n.startswith('hold'))
print('hold* instances', sum(hc.values()), hc.most_common(6))
pref=collections.Counter(re.sub(r'\d+$','',n) for n in cells if re.match(r'[a-z]',n))
print(pref.most_common(15))
