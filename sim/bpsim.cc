// Trace-driven driver: bpsim name key=val ... -- trace files
#include "bp_model.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#pragma pack(push, 1)
struct Rec { uint32_t pc, target; uint16_t gap; uint8_t type, taken; };
#pragma pack(pop)
int main(int argc, char **argv) {
  Cfg c; std::string name = argv[1]; int a = 2;
  for (; a < argc && strcmp(argv[a], "--"); a++) {
    char *eq = strchr(argv[a], '='); *eq = 0; std::string k = argv[a]; const char *v = eq + 1; int n = atoi(v);
    if (k == "kind") c.kind = n; else if (k == "LB") c.LB = n; else if (k == "TBB") c.TBB = n; else if (k == "TW") c.TW = n;
    else if (k == "LR") c.LR = n; else if (k == "LBIM") c.LBIM = n; else if (k == "HG") c.HG = n; else if (k == "NT") c.NT = n;
    else if (k == "LT") c.LT = n; else if (k == "TT") c.TT = n; else if (k == "UB") c.UB = n; else if (k == "LRST") c.LRST = n;
    else if (k == "LI") c.LI = n; else if (k == "TI") c.TI = n; else if (k == "HT") c.HT = n; else if (k == "delay") c.delay = n;
    else if (k == "phantom") c.phantom = n; else if (k == "allhist") c.allhist = n; else if (k == "nobtb") c.nobtb = n;
    else if (k == "hist") { int i = 0; for (const char *p = v; *p && i < MAXT; i++) { c.hist[i] = atoi(p); p = strchr(p, ','); if (!p) break; p++; } }
    else { fprintf(stderr, "bad key %s\n", k.c_str()); return 1; }
  }
  for (a++; a < argc; a++) {
    FILE *f = fopen(argv[a], "rb"); if (!f) continue;
    fseek(f, 0, SEEK_END); size_t n = ftell(f) / sizeof(Rec); fseek(f, 0, SEEK_SET);
    std::vector<Rec> t(n); if (fread(t.data(), sizeof(Rec), n, f) != n) return 1; fclose(f);
    BP bp(c); Meta m; uint64_t ph2 = 0;
    for (const Rec &r : t) {
      bp.s.instr += r.gap;
      if (c.phantom && r.gap < 65535) for (uint32_t pc = r.pc - 4 * (r.gap - 1); pc != r.pc; pc += 4) ph2 += bp.step_nonbranch(pc) == 2;
      bp.step(r.pc, r.target, r.type, r.taken, m);
    }
    const Stats &s = bp.s; std::string tn = argv[a]; tn = tn.substr(tn.rfind('/') + 1); tn = tn.substr(0, tn.size() - 4);
    printf("%s,%d,%s,%llu", name.c_str(), c.bits(), tn.c_str(), (unsigned long long)s.instr);
    for (int i = 0; i < 6; i++) printf(",%llu", (unsigned long long)s.br[i]);
    printf(",%llu,%llu", (unsigned long long)s.cond_taken, (unsigned long long)s.dir_wrong);
    for (int i = 0; i < 6; i++) printf(",%llu", (unsigned long long)s.mis[i]);
    for (int i = 0; i < 6; i++) printf(",%llu", (unsigned long long)s.idr[i]);
    printf(",%llu,%llu,%llu,%llu,%llu\n", (unsigned long long)s.phantom, (unsigned long long)ph2, (unsigned long long)s.taken_cf, (unsigned long long)s.taken_hit0, (unsigned long long)s.slow_diff);
  }
}
