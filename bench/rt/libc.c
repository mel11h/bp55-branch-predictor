#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
void *memcpy(void *d, const void *s, size_t n){char *a=d;const char *b=s;while(n--)*a++=*b++;return d;}
void *memmove(void *d, const void *s, size_t n){char *a=d;const char *b=s;if(a<b)while(n--)*a++=*b++;else{a+=n;b+=n;while(n--)*--a=*--b;}return d;}
void *memset(void *d, int c, size_t n){char *a=d;while(n--)*a++=c;return d;}
int memcmp(const void *x, const void *y, size_t n){const unsigned char *a=x,*b=y;for(;n--;a++,b++)if(*a!=*b)return *a-*b;return 0;}
void *memchr(const void *x,int c,size_t n){const unsigned char *a=x;for(;n--;a++)if(*a==(unsigned char)c)return (void*)a;return 0;}
size_t strlen(const char *s){size_t n=0;while(s[n])n++;return n;}
char *strcpy(char *d,const char *s){char *r=d;while((*d++=*s++));return r;}
char *strncpy(char *d,const char *s,size_t n){size_t i=0;for(;i<n&&s[i];i++)d[i]=s[i];for(;i<n;i++)d[i]=0;return d;}
int strcmp(const char *a,const char *b){while(*a&&*a==*b){a++;b++;}return (unsigned char)*a-(unsigned char)*b;}
int strncmp(const char *a,const char *b,size_t n){for(;n;n--,a++,b++){if(*a!=*b)return (unsigned char)*a-(unsigned char)*b;if(!*a)break;}return 0;}
char *strchr(const char *s,int c){for(;;s++){if(*s==(char)c)return (char*)s;if(!*s)return 0;}}
char *strrchr(const char *s,int c){const char *r=0;for(;;s++){if(*s==(char)c)r=s;if(!*s)return (char*)r;}}
char *strcat(char *d,const char *s){strcpy(d+strlen(d),s);return d;}
int abs(int x){return x<0?-x:x;}
long labs(long x){return x<0?-x:x;}
int atoi(const char *s){int v=0,n=0;while(*s==' ')s++;if(*s=='-'){n=1;s++;}while(*s>='0'&&*s<='9')v=v*10+*s++-'0';return n?-v:v;}
static unsigned long rs=1;
int rand(void){rs=rs*1103515245+12345;return (rs>>16)&32767;}
void srand(unsigned s){rs=s;}
int putchar(int c){register long a0 __asm__("a0")=c;register long a7 __asm__("a7")=64;__asm__ volatile("ecall"::"r"(a0),"r"(a7));return c;}
int puts(const char *s){while(*s)putchar(*s++);putchar('\n');return 0;}
int printf(const char *f,...){(void)f;return 0;}
int sprintf(char *b,const char *f,...){(void)f;*b=0;return 0;}
void exit(int c){register long a0 __asm__("a0")=c;register long a7 __asm__("a7")=93;__asm__ volatile("ecall"::"r"(a0),"r"(a7));for(;;);}
extern char _end[];
static char *brk=0;
void *malloc(size_t n){if(!brk)brk=(char*)(((uintptr_t)_end+0x100000+15)&~15u);void *p=brk;brk+=(n+15)&~15u;return p;}
void *calloc(size_t a,size_t b){void *p=malloc(a*b);memset(p,0,a*b);return p;}
void free(void *p){(void)p;}
uint64_t __udivmoddi4(uint64_t n,uint64_t d,uint64_t *r){uint64_t q=0,rem=0;for(int i=63;i>=0;i--){rem=(rem<<1)|((n>>i)&1);if(rem>=d){rem-=d;q|=1ull<<i;}}if(r)*r=rem;return q;}
uint64_t __udivdi3(uint64_t n,uint64_t d){return __udivmoddi4(n,d,0);}
uint64_t __umoddi3(uint64_t n,uint64_t d){uint64_t r;__udivmoddi4(n,d,&r);return r;}
int64_t __divdi3(int64_t a,int64_t b){int s=(a<0)^(b<0);uint64_t q=__udivmoddi4(a<0?-(uint64_t)a:a,b<0?-(uint64_t)b:b,0);return s?-(int64_t)q:q;}
int64_t __moddi3(int64_t a,int64_t b){uint64_t r;__udivmoddi4(a<0?-(uint64_t)a:a,b<0?-(uint64_t)b:b,&r);return a<0?-(int64_t)r:r;}
void qsort(void *base,size_t n,size_t sz,int(*cmp)(const void*,const void*)){char *b=base;char t[64];for(size_t g=n/2;g;g/=2)for(size_t i=g;i<n;i++)for(size_t j=i;j>=g&&cmp(b+(j-g)*sz,b+j*sz)>0;j-=g){memcpy(t,b+j*sz,sz);memcpy(b+j*sz,b+(j-g)*sz,sz);memcpy(b+(j-g)*sz,t,sz);}}
void abort(void){exit(99);}
