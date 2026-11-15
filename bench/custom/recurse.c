// Call/return and data-dependent branch stress: recursion, BST, function-pointer sort, binary search.
#include <stdint.h>
#include <stdlib.h>
static uint32_t s = 2463534242u;
static uint32_t rnd(void) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static int ack(int m, int n) { return m == 0 ? n + 1 : n == 0 ? ack(m - 1, 1) : ack(m - 1, ack(m, n - 1)); }
typedef struct node { struct node *l, *r; int k; } node;
static node pool[4096]; static int np;
static node *ins(node *t, int k) { if (!t) { t = &pool[np++]; t->l = t->r = 0; t->k = k; return t; } if (k < t->k) t->l = ins(t->l, k); else t->r = ins(t->r, k); return t; }
static int depth(node *t) { if (!t) return 0; int a = depth(t->l), b = depth(t->r); return 1 + (a > b ? a : b); }
static int sum(node *t) { return t ? t->k + sum(t->l) + sum(t->r) : 0; }
static int cmp_up(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }
static int cmp_dn(const void *a, const void *b) { return *(const int *)b - *(const int *)a; }
static int cmp_mod(const void *a, const void *b) { return (*(const int *)a % 97) - (*(const int *)b % 97); }
static int arr[2048];
static int bsearch_i(int k) { int lo = 0, hi = 2047; while (lo < hi) { int m = (lo + hi) / 2; if (arr[m] < k) lo = m + 1; else hi = m; } return lo; }
int main(void) {
  volatile int acc = 0;
  int (*cmps[3])(const void *, const void *) = { cmp_up, cmp_dn, cmp_mod };
  for (int it = 0; it < 2; it++) {
    acc += fib(18) + ack(2, 40 + it);
    np = 0; node *t = 0; for (int i = 0; i < 3000; i++) t = ins(t, rnd() & 0xffff);
    acc += depth(t) + sum(t);
    for (int i = 0; i < 2048; i++) arr[i] = rnd() & 0xfffff;
    qsort(arr, 2048, sizeof(int), cmps[it % 3]); qsort(arr, 2048, sizeof(int), cmp_up);
    for (int i = 0; i < 20000; i++) acc += bsearch_i(rnd() & 0xfffff);
  }
  return acc == 0x7fffffff;
}
