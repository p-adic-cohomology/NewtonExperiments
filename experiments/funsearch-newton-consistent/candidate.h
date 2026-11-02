#ifndef FUNSEARCH_NEWTON_CANDIDATE_H
#define FUNSEARCH_NEWTON_CANDIDATE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Fill the 21 degree-five monomial coefficients over F_p.
 * Entry k corresponds to x^i y^j z^(5-i-j), ordered by increasing i and then j.
 * Every entry must be in [0, p), and the vector must not be all zero.
 */
void curve(int32_t p, int32_t coeffs[21]);

#ifdef __cplusplus
}
#endif

#endif
