## Android bionic arm64, derived from NDK pthread_types.h (40-byte mutex).
typedef struct
{
  long _vers;
  union {
    volatile char _priv[40];
    long _x_align;
    long *_xp_align;
  } u;
} gpgrt_lock_t;

#define GPGRT_LOCK_INITIALIZER {1,{{0}}}
##
