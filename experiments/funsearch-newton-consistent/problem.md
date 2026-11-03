# Mathematical goal

Construct smooth plane quintics over a finite field. A candidate is a deterministic generator of `K` curves, so the score measures the quality and variety of the construction rather than one lucky curve.

## Candidate interface

The candidate exports `curve(p, k, coeffs)` as declared in `candidate.h`. It fills all 21 coefficients of the degree-five homogeneous polynomial for prime `p` and zero-based sample index `k`, where `0 <= k < K`. Each output must depend only on `(p, k)`; do not rely on previous calls, global mutable state, or evaluator-owned data.

The coefficient order is `x^i y^j z^(5-i-j)`, with `i` increasing from 0 to 5 and then `j` increasing from 0 to `5-i`. Every coefficient must be an integer from 0 through `p-1`, the vector must be nonzero, and the polynomial must define a smooth projective curve.

## Scoring

For each sample, the evaluator computes the zeta function over `F_p`, its Newton polygon, and its codimension `c` in the genus-six moduli space. A supersingular curve uses `ss_codim` in place of `c` (default 1). The per-curve reward `r` is `log2(1 + c')` when `curve_reward=log` and `c'` when `curve_reward=linear`, where `c'` is the adjusted codimension.

Curves in one batch are deduplicated by their zeta function, which identifies the isogeny class of the Jacobian. The first occurrence in `k` order receives its per-curve reward; each later occurrence receives zero. Invalid samples also contribute zero. With `r_i` denoting these rewards, the program score is:

```text
S = (sum(r_i) / K) + lambda * max(r_i) + beta * I(any valid sample has a novel polygon)
```

The mean always divides by `K`, including invalid samples and duplicates. The novelty indicator is one when at least one successfully evaluated sample has a Newton polygon absent from both reference tables for that prime. The published and locally known polygons are loaded once at server startup. Defaults are `K=16`, `lambda=0.25`, and `beta=0.5`.

Coordinate changes in `PGL(3)`, variable rescalings, and rescaling the equation preserve the zeta function. They therefore produce the same class and add no score when repeated within a batch.

Malformed coefficients and singular curves have sample status `INVALID`. A batch with no valid sample is `INVALID`. Any sample evaluation failure makes the whole batch `ERROR`; evaluation failures never become silent zero rewards.

## Message legend

The response `msg` starts with `S=<score> distinct=<count>/<K>`, followed by one token per sample in `k` order. A number is the adjusted codimension; `ss` marks a supersingular sample; `d` marks a repeated zeta function. `i` means invalid and `e` means evaluation error. For example, `1ssd` is a supersingular sample with adjusted codimension 1 whose zeta function appeared earlier. If the message would exceed 255 bytes, the evaluator ends it with `+N more`.

## Public constraints

The supported family is `family=plane,d=5`, with prime `p` and `1 <= K <= 64`. Candidates must fill every coefficient on every call, use only the supplied prime and sample index, and return coefficients in the prime field. The evaluator independently constructs the curve and checks projective smoothness; candidates must not rely on evaluator internals or previously generated curves.
