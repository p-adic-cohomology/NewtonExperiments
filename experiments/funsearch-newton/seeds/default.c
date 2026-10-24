#include "candidate.h"

void curve(int32_t p, int32_t coeffs[21])
{
    uint32_t state = UINT32_C(0x5eed1234);
    int nonzero = 0;
    for (int i = 0; i < 21; ++i) {
        state = state * UINT32_C(1664525) + UINT32_C(1013904223);
        coeffs[i] = (int32_t)((state >> 16) % (uint32_t)p);
        nonzero |= coeffs[i] != 0;
    }
    if (!nonzero)
        coeffs[0] = 1;
}
