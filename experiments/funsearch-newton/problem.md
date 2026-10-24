# Mathematical goal

Construct smooth plane quintics over a finite field and maximize the depth of
their Newton polygons. A higher score means a deeper Newton stratum, with a
small bonus when the polygon is absent from the reference set for the same
prime. Supersingular curves are assigned score zero by default.

## Instance and candidate interface

An instance is a comma-separated string with these fields:

- family: plane
- d: 5
- p: a prime
- reward: mixed, depth, or novelty
- beta: nonnegative finite bonus for mixed reward
- eps: nonnegative finite weight for depth under novelty reward
- exclude_ss: true or false

The defaults are plane quintics, mixed reward, beta 0.5, eps 0.01, and
excluding supersingular curves. The first configured prime is 7.

The candidate exports one function with the prototype in candidate.h. It fills
21 coefficients in the prime field, in this order: x^i y^j z^(5-i-j), with i
increasing from 0 to 5 and j increasing from 0 to 5-i. Every coefficient must
be in the range 0 through p-1, and the vector must not be all zero. The
resulting homogeneous polynomial must define a smooth projective curve.

## Scoring

For genus 6, the evaluator computes the Newton polygon and its stratum
codimension in the moduli space of principally polarized abelian varieties.
The codimension is 21 minus sdim, where sdim counts the integer lattice pairs
(x,y) with 0 <= y < x <= 6 that lie on or above the polygon. The mixed reward
is codimension plus beta times a binary novelty bonus. The depth reward is
codimension. The novelty reward is the novelty bonus plus eps times
codimension. A polygon is novel when its integer-abscissa values are not in
the reference set for that prime.

The evaluator independently constructs and checks the curve. Invalid
coefficients and singular curves receive INVALID. An evaluation failure
receives ERROR. Only a successfully computed polygon receives OK. The signature
contains the polygon values at integer abscissas 1 through 6; it groups similar
outputs and does not affect ranking.

## Starting candidates

The default seed is a fixed deterministic pseudo-random coefficient vector.
Alternative seeds are kept under seeds/; to use one, copy it to seed.c before
checking or starting a run. At p=7 the default seed is smooth and ordinary, so
it scores 0 under the default mixed reward. Runs retain their own copy of the
selected seed.

## Public constraints

Candidates must be deterministic for a given prime and must fill every output
coefficient on every call. Do not rely on previous calls, global mutable state,
or data owned by the evaluator. The evaluator treats the candidate as a
constructor and checks the curve it actually produces.
