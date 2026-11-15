sols=[]
for LB in range(5,13):
 for LBIM in range(8,15):
  for TT in range(7,16):
   for LI in range(0,11):
    for HT in (6,8,10,12):
     for LRST in range(9,20):
      for H in range(20,65):
        b=(1<<LB)*30+(8*30+3)+(1<<LBIM)*2+5*1024*(TT+4)+H+4+LRST+((1<<LI)*27+HT if LI else 0)
        if b==122952: sols.append((LB,LBIM,TT,LI,HT,LRST,H))
print(len(sols)); print(sols[:40])
# with big_tage_u1 = 122958 (6 more bits): same with HT+6?
