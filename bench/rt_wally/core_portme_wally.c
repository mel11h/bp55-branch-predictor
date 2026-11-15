/* CoreMark port for the CORE-V Wally build (bench/build_wally.sh).
 * Identical to cm_port/core_portme.c (same seeds, no timer: get_time() returns
 * 0), except that ee_printf formats its arguments and writes them to the
 * console through putchar (rt_wally/io_wally.S on Wally, io_iss.S on rvsim),
 * so the CRC values CoreMark computes are visible and can be checked.
 * Supports what core_main.c uses with HAS_FLOAT 0: %d %i %u %x %X %s %c %%
 * with an optional '0' flag, field width and 'l' length modifier. */
#include <stdarg.h>
#include "coremark.h"
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415; volatile ee_s32 seed2_volatile = 0x3415; volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0; volatile ee_s32 seed2_volatile = 0x0; volatile ee_s32 seed3_volatile = 0x66;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS; volatile ee_s32 seed5_volatile = 0;
void start_time(void) {} void stop_time(void) {}
CORE_TICKS get_time(void) { return 0; }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)ticks; }
ee_u32 default_num_contexts = 1;
void portable_init(core_portable *p, int *argc, char *argv[]) { (void)argc; (void)argv; p->portable_id = 1; }
void portable_fini(core_portable *p) { p->portable_id = 0; }

int putchar(int c);

static int emit_num(unsigned long v, unsigned base, int upper, int neg, int width, char pad) {
  char buf[16]; int n = 0, out = 0;
  const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  do { buf[n++] = dig[v % base]; v /= base; } while (v);
  if (neg) {
    if (pad == '0') { putchar('-'); out++; width--; } else buf[n++] = '-';
  }
  for (; width > n; width--, out++) putchar(pad);
  while (n) { putchar(buf[--n]); out++; }
  return out;
}

int ee_printf(const char *fmt, ...) {
  va_list ap; int out = 0;
  va_start(ap, fmt);
  for (; *fmt; fmt++) {
    if (*fmt != '%') { putchar(*fmt); out++; continue; }
    fmt++;
    char pad = ' '; int width = 0;
    if (*fmt == '0') { pad = '0'; fmt++; }
    while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
    while (*fmt == 'l') fmt++;
    switch (*fmt) {
    case 'd': case 'i': { long v = va_arg(ap, long);
      out += emit_num(v < 0 ? -(unsigned long)v : (unsigned long)v, 10, 0, v < 0, width, pad); break; }
    case 'u': out += emit_num(va_arg(ap, unsigned long), 10, 0, 0, width, pad); break;
    case 'x': out += emit_num(va_arg(ap, unsigned long), 16, 0, 0, width, pad); break;
    case 'X': out += emit_num(va_arg(ap, unsigned long), 16, 1, 0, width, pad); break;
    case 'c': putchar(va_arg(ap, int)); out++; break;
    case 's': { const char *s = va_arg(ap, const char *); int n = 0;
      while (s[n]) n++;
      for (; width > n; width--, out++) putchar(' ');
      while (*s) { putchar(*s++); out++; } break; }
    case '%': putchar('%'); out++; break;
    case 0: fmt--; break;
    default: putchar('%'); putchar(*fmt); out += 2; break;
    }
  }
  va_end(ap);
  return out;
}
