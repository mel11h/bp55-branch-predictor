#pragma once
#include <stddef.h>
int abs(int); long labs(long); int atoi(const char *); void exit(int) __attribute__((noreturn));
void *malloc(size_t); void *calloc(size_t, size_t); void *realloc(void *, size_t); void free(void *);
int rand(void); void srand(unsigned);
void qsort(void *, size_t, size_t, int (*)(const void *, const void *));
#define RAND_MAX 32767
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
void abort(void) __attribute__((noreturn));
