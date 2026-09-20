#ifndef DJONEHUB_INTERNET_POLICY_H
#define DJONEHUB_INTERNET_POLICY_H
#include <stdint.h>
/* 0 unknown, 1 disabled, 2 enabled. */
uint8_t djonehub_internet_state(void);
int djonehub_internet_set(int enabled);
void djonehub_internet_restore(void);
#endif
