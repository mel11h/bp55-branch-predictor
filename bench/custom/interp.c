// Bytecode VM with switch dispatch (indirect-branch stress) running several small programs.
#include <stdint.h>
enum { PUSH, ADD, SUB, MUL, DUP, SWAP, DROP, JNZ, JMP, LOAD, STORE, LT, AND, XOR, SHR, CALL, RET, HALT, INC, DEC, OVER, MOD };
static int32_t stack[256], mem[64], rstack[64];
static int run(const int16_t *code) {
  int sp = 0, rp = 0, pc = 0; int32_t a, b;
  for (;;) {
    switch (code[pc++]) {
    case PUSH: stack[sp++] = code[pc++]; break;
    case ADD: b = stack[--sp]; stack[sp-1] += b; break;
    case SUB: b = stack[--sp]; stack[sp-1] -= b; break;
    case MUL: b = stack[--sp]; stack[sp-1] *= b; break;
    case MOD: b = stack[--sp]; stack[sp-1] = (uint32_t)stack[sp-1] % (uint32_t)(b|1); break;
    case DUP: stack[sp] = stack[sp-1]; sp++; break;
    case OVER: stack[sp] = stack[sp-2]; sp++; break;
    case SWAP: a = stack[sp-1]; stack[sp-1] = stack[sp-2]; stack[sp-2] = a; break;
    case DROP: sp--; break;
    case JNZ: a = stack[--sp]; if (a) pc = code[pc]; else pc++; break;
    case JMP: pc = code[pc]; break;
    case LOAD: stack[sp++] = mem[code[pc++]]; break;
    case STORE: mem[code[pc++]] = stack[--sp]; break;
    case LT: b = stack[--sp]; stack[sp-1] = stack[sp-1] < b; break;
    case AND: b = stack[--sp]; stack[sp-1] &= b; break;
    case XOR: b = stack[--sp]; stack[sp-1] ^= b; break;
    case SHR: b = stack[--sp]; stack[sp-1] = (uint32_t)stack[sp-1] >> (b & 31); break;
    case INC: stack[sp-1]++; break;
    case DEC: stack[sp-1]--; break;
    case CALL: rstack[rp++] = pc + 1; pc = code[pc]; break;
    case RET: pc = rstack[--rp]; break;
    case HALT: return stack[sp-1];
    }
  }
}
// prog1: sum of collatz steps for n=1..N ; prog2: LFSR-driven data dependent mix ; prog3: nested loops w/ call
static const int16_t p1[] = { PUSH,0,STORE,0, PUSH,1,STORE,1,
 /*8*/ LOAD,1, /*10: loop n on stack*/ DUP,PUSH,1,XOR,JNZ,18, DROP,JMP,46,
 /*18*/ LOAD,0,INC,STORE,0, DUP,PUSH,1,AND,JNZ,36, PUSH,1,SHR,JMP,10,
 /*36*/ DUP,DUP,ADD,ADD,INC,JMP,10, 0,0,0,
 /*46*/ LOAD,1,INC,DUP,STORE,1,PUSH,400,LT,JNZ,8, LOAD,0,HALT };
static const int16_t p2[] = { PUSH,12345,STORE,0, PUSH,0,STORE,1, PUSH,3000,STORE,2,
 /*12*/ LOAD,0,DUP,PUSH,1,AND,JNZ,24, PUSH,1,SHR,JMP,31,
 /*24*/ PUSH,1,SHR,PUSH,0x6C01,XOR,
 /*30*/ 0+DUP,/*31*/ DUP,STORE,0, PUSH,7,MOD,CALL,60, LOAD,1,ADD,STORE,1,
 LOAD,2,DEC,DUP,STORE,2,JNZ,12, LOAD,1,HALT, 0,0,0,0,0,
 /*60*/ DUP,PUSH,3,LT,JNZ,70, DUP,MUL,RET, 0,
 /*70*/ PUSH,5,ADD,RET };
int main(void) {
  volatile int acc = 0;
  for (int i = 0; i < 100; i++) { acc += run(p1); acc ^= run(p2); }
  return acc == 0x7fffffff;
}
