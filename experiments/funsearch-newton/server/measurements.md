# Server measurements

Measured on Julia 1.13.2 with DeRham 59b331b818aaa7f169a33c42e600cbc6de9044f7. Load time covers the server module imports and reference-table load. Warm-up latency is the first Fermat quintic p=7 score. Steady time is the median score time over 20 random smooth quintics at p=7; singular samples were skipped, and evaluation errors abort the measurement.

Re-measured at commit 9f341e1 with the fixed sampler, default image, on a heavily loaded host (load average about 14):

| Runtime | Module load | First-call warm-up | Steady p=7 min / median / max | Peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Julia default image | 18.978 s | 6.907 s | 0.538 / 1.111 / 2.002 s (20 smooth, 26 attempts, 0 errors) | 3,174,580,224 bytes |

Earlier measurements, taken before the sampler fix, when non-OK results were dropped without being reported (historical):

| Runtime | Module load | First-call warm-up | Median steady p=7 | Peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Julia default image | 17.102 s | 3.772 s | 0.529 s (20 smooth, 26 attempts) | 2,595,274,752 bytes |
| City sysimage `be6cc6b3…` | 10.989 s | 3.080 s | 0.413 s (20 smooth, 26 attempts) | 3,073,900,544 bytes |

Steady-state time is sensitive to host load; the minimum matches the earlier median.

The no-image measurement used the canonical DeRham checkout at `/Users/Shared/Developer/ai/city/math-code-projects/DeRham.jl`. The sysimage measurement selected artifact `be6cc6b35c11eef2b1077e5e0b0d3874f540d2a6872f2253f7ed2eb329487640`; its actual image was `/Users/Shared/Developer/ai/city/math-city/.gc/kaimon-sysimages/mc-xf9j5/union-artifacts/be6cc6b35c11eef2b1077e5e0b0d3874f540d2a6872f2253f7ed2eb329487640/image.dylib`. It loaded DeRham from the retained reference worktree at `/Users/Shared/Developer/ai/city/math-city/.gc/kaimon-sysimages/mc-xf9j5/workloads/DeRham.jl`, at the same commit.

Both runs reported the table precision path for the warm-up curve at `(n=2, d=5, p=7)`, with `r_m=[4,4]`, `N_m=[4,4]`, and `M=7`. The native Kaimon benchmark eval stayed busy without CPU progress for 2m52 and was canceled; the sysimage figure came from the documented per-worktree wrapper, which printed the selected artifact and reported the actual `julia_image_file` above.
