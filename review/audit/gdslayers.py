import os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..') + '/'
import gzip, struct, collections
f=gzip.open(ROOT+'pnr/bp55.gds.gz','rb'); data=f.read()
i=0; cur=None; L=None; per=collections.defaultdict(collections.Counter); el=None; units=None
while i < len(data):
    ln,rt,dt=struct.unpack('>HBB',data[i:i+4]); body=data[i+4:i+ln]
    if ln==0: break
    if rt==0x06: cur=body.rstrip(b'\0').decode()
    elif rt in (0x08,0x09,0x0C,0x2D): el=rt; lay=None; dtp=None
    elif rt==0x0D: lay=struct.unpack('>h',body[:2])[0]
    elif rt in (0x0E,0x16): dtp=struct.unpack('>h',body[:2])[0]
    elif rt==0x11:
        if lay is not None: per['TOP' if cur=='bp55' else 'CELLS'][(lay,dtp,{8:'B',9:'P',12:'T',45:'X'}.get(el))]+=1
    elif rt==0x03: units=body
    i+=ln
for k,v in per.items(): print(k, sorted(v.items()))
