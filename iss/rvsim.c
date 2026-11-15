// Minimal RV32IM instruction-set simulator that emits a control-flow trace.
// usage: rvsim prog.bin trace.out [max_instr]
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MEMSZ (64u << 20)
static uint8_t *mem;
static uint32_t x[32], pc;

enum { T_COND = 0, T_JUMP = 1, T_CALL = 2, T_RET = 3, T_IND = 4, T_ICALL = 5 };
#pragma pack(push, 1)
typedef struct { uint32_t pc, target; uint16_t gap; uint8_t type, taken; } rec_t;
#pragma pack(pop)

static inline uint32_t rd32(uint32_t a) { uint32_t v; if (a > MEMSZ - 4) { fprintf(stderr, "bad load %08x pc=%08x\n", a, pc); exit(2);} memcpy(&v, mem + a, 4); return v; }
static inline void wr(uint32_t a, uint32_t v, int n) { if (a > MEMSZ - 4) { fprintf(stderr, "bad store %08x pc=%08x\n", a, pc); exit(2);} memcpy(mem + a, &v, n); }
static inline int islink(uint32_t r) { return r == 1 || r == 5; }

int main(int argc, char **argv) {
  if (argc < 3) return 1;
  uint64_t maxi = argc > 3 ? strtoull(argv[3], 0, 0) : ~0ull;
  mem = calloc(MEMSZ, 1);
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror("bin"); return 1; }
  size_t n = fread(mem, 1, MEMSZ, f); fclose(f); (void)n;
  FILE *t = fopen(argv[2], "wb");
  static rec_t buf[1 << 16]; int nb = 0;
  uint64_t icount = 0, last = 0, nbr = 0;
  pc = 0; x[2] = MEMSZ - 16;
  int rc = -1;
  while (icount < maxi) {
    uint32_t i = rd32(pc), op = i & 0x7f, rd = (i >> 7) & 31, f3 = (i >> 12) & 7, rs1 = (i >> 15) & 31, rs2 = (i >> 20) & 31, f7 = i >> 25;
    uint32_t a = x[rs1], b = x[rs2], npc = pc + 4, v = 0; int w = 1, br = -1, taken = 1; uint32_t tgt = 0;
    int32_t immi = (int32_t)i >> 20;
    icount++;
    switch (op) {
    case 0x37: v = i & 0xfffff000; break;
    case 0x17: v = pc + (i & 0xfffff000); break;
    case 0x6f: { int32_t o = ((int32_t)(i & 0x80000000) >> 11) | (i & 0xff000) | ((i >> 9) & 0x800) | ((i >> 20) & 0x7fe);
      v = npc; tgt = pc + o; br = islink(rd) ? T_CALL : T_JUMP; npc = tgt; break; }
    case 0x67: { v = npc; tgt = (a + immi) & ~1u;
      if (islink(rd)) br = T_ICALL; else if (islink(rs1)) br = T_RET; else br = T_IND;
      npc = tgt; break; }
    case 0x63: { int32_t o = ((int32_t)(i & 0x80000000) >> 19) | ((i << 4) & 0x800) | ((i >> 20) & 0x7e0) | ((i >> 7) & 0x1e);
      int c;
      switch (f3) { case 0: c = a == b; break; case 1: c = a != b; break; case 4: c = (int32_t)a < (int32_t)b; break;
        case 5: c = (int32_t)a >= (int32_t)b; break; case 6: c = a < b; break; case 7: c = a >= b; break; default: goto ill; }
      w = 0; br = T_COND; taken = c; tgt = pc + o; if (c) npc = tgt; break; }
    case 0x03: { uint32_t ad = a + immi, d = rd32(ad);
      switch (f3) { case 0: v = (int8_t)d; break; case 1: v = (int16_t)d; break; case 2: v = d; break; case 4: v = d & 0xff; break; case 5: v = d & 0xffff; break; default: goto ill; }
      break; }
    case 0x23: { int32_t o = ((int32_t)i >> 25 << 5) | rd; w = 0;
      wr(a + o, b, f3 == 0 ? 1 : f3 == 1 ? 2 : 4); break; }
    case 0x13: { uint32_t sh = rs2;
      switch (f3) { case 0: v = a + immi; break; case 2: v = (int32_t)a < immi; break; case 3: v = a < (uint32_t)immi; break;
        case 4: v = a ^ immi; break; case 6: v = a | immi; break; case 7: v = a & immi; break;
        case 1: v = a << sh; break; case 5: v = (f7 & 0x20) ? (uint32_t)((int32_t)a >> sh) : a >> sh; break; }
      break; }
    case 0x33:
      if (f7 == 1) {
        switch (f3) {
        case 0: v = a * b; break;
        case 1: v = ((int64_t)(int32_t)a * (int64_t)(int32_t)b) >> 32; break;
        case 2: v = ((int64_t)(int32_t)a * (uint64_t)b) >> 32; break;
        case 3: v = ((uint64_t)a * b) >> 32; break;
        case 4: v = b == 0 ? ~0u : (a == 0x80000000 && b == ~0u) ? a : (uint32_t)((int32_t)a / (int32_t)b); break;
        case 5: v = b == 0 ? ~0u : a / b; break;
        case 6: v = b == 0 ? a : (a == 0x80000000 && b == ~0u) ? 0 : (uint32_t)((int32_t)a % (int32_t)b); break;
        case 7: v = b == 0 ? a : a % b; break; }
      } else {
        switch (f3) { case 0: v = (f7 & 0x20) ? a - b : a + b; break; case 1: v = a << (b & 31); break;
          case 2: v = (int32_t)a < (int32_t)b; break; case 3: v = a < b; break; case 4: v = a ^ b; break;
          case 5: v = (f7 & 0x20) ? (uint32_t)((int32_t)a >> (b & 31)) : a >> (b & 31); break;
          case 6: v = a | b; break; case 7: v = a & b; break; }
      }
      break;
    case 0x0f: w = 0; break;
    case 0x73: w = 0;
      if (x[17] == 93) { rc = x[10]; goto done; }
      if (x[17] == 64) { fputc(x[10], stderr); }
      break;
    default: ill: fprintf(stderr, "illegal insn %08x at %08x\n", i, pc); rc = 3; goto done;
    }
    if (w && rd) x[rd] = v;
    if (br >= 0) {
      uint64_t g = icount - last; last = icount; nbr++;
      rec_t r = { pc, tgt, g > 65535 ? 65535 : (uint16_t)g, (uint8_t)br, (uint8_t)taken };
      buf[nb++] = r; if (nb == (1 << 16)) { fwrite(buf, sizeof(rec_t), nb, t); nb = 0; }
    }
    pc = npc;
  }
done:
  fwrite(buf, sizeof(rec_t), nb, t); fclose(t);
  fprintf(stderr, "\n[rvsim] exit=%d instr=%llu branches=%llu\n", rc, (unsigned long long)icount, (unsigned long long)nbr);
  return rc == 0 ? 0 : 1;
}
