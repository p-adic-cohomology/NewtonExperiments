#include "candidate.h"

void curve(int32_t p, int32_t coeffs[21])
{
    static const int32_t values[21] = {
        4, 1, 5, 2, 6, 3, 0, 2, 5, 1, 4,
        6, 3, 0, 5, 2, 4, 1, 6, 3, 5
    };
    for (int i = 0; i < 21; ++i)
        coeffs[i] = values[i] % p;
}
