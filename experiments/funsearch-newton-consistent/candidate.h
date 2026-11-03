#ifndef FUNSEARCH_NEWTON_CANDIDATE_H
#define FUNSEARCH_NEWTON_CANDIDATE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Generate the k-th degree-five curve over F_p.
 * Coefficient entries correspond to x^i y^j z^(5-i-j), ordered by increasing i and then j.
 * Each output depends only on p and k. Invalid samples are scored as zero.
 */
void curve(int32_t p, int32_t k, int32_t coeffs[21]);

#ifdef __cplusplus
}
#endif

#endif
