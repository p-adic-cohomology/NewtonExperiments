#include "candidate.h"

void curve(int32_t p, int32_t k, int32_t coeffs[21])
{
    uint32_t state = UINT32_C(0xabcde123) ^ ((uint32_t)k * UINT32_C(0x85ebca6b));
    int nonzero = 0;
    for (int i = 0; i < 21; ++i) {
        state = state * UINT32_C(1103515245) + UINT32_C(12345);
        coeffs[i] = (int32_t)((state >> 16) % (uint32_t)p);
        nonzero |= coeffs[i] != 0;
    }
    if (!nonzero)
        coeffs[0] = 1;
}
