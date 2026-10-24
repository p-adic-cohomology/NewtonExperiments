# Server measurements

Measured on Julia 1.13.2 with DeRham 59b331b818aaa7f169a33c42e600cbc6de9044f7. Load time covers the server module imports and reference-table load. Warm-up latency is the first Fermat quintic p=7 score. Steady time is the median score time over 20 random smooth quintics at p=7; singular samples were skipped, and evaluation errors abort the measurement.

| Runtime | Module load | First-call warm-up | Median steady p=7 | Peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Julia default image | 17.102 s | 3.772 s | 0.529 s (20 smooth, 26 attempts) | 2,595,274,752 bytes |
| City sysimage `be6cc6b3…` | 10.989 s | 3.080 s | 0.413 s (20 smooth, 26 attempts) | 3,073,900,544 bytes |

The no-image measurement used the canonical DeRham checkout at `/Users/Shared/Developer/ai/city/math-code-projects/DeRham.jl`. The sysimage measurement selected artifact `be6cc6b35c11eef2b1077e5e0b0d3874f540d2a6872f2253f7ed2eb329487640`; its actual image was `/Users/Shared/Developer/ai/city/math-city/.gc/kaimon-sysimages/mc-xf9j5/union-artifacts/be6cc6b35c11eef2b1077e5e0b0d3874f540d2a6872f2253f7ed2eb329487640/image.dylib`. It loaded DeRham from the retained reference worktree at `/Users/Shared/Developer/ai/city/math-city/.gc/kaimon-sysimages/mc-xf9j5/workloads/DeRham.jl`, at the same commit.

Both runs reported the table precision path for the warm-up curve at `(n=2, d=5, p=7)`, with `r_m=[4,4]`, `N_m=[4,4]`, and `M=7`. The native Kaimon benchmark eval stayed busy without CPU progress for 2m52 and was canceled; the sysimage figure came from the documented per-worktree wrapper, which printed the selected artifact and reported the actual `julia_image_file` above.

## C shim acceptance (2026-10-24)

The shim unit tests passed against a stub Unix-socket server: valid response
mapping, zero and out-of-range coefficient rejection, unavailable-server
`ERROR`, and reconnect after the server closed the first connection. The pack
worktree used for the macOS build and check was `polecat/mx-prpp` at
`246de5b78fa140b798519738359aa4b48bfa8bc3`.

The managed real-server check used Julia 1.13.2 with the default image and
DeRham `59b331b818aaa7f169a33c42e600cbc6de9044f7` from
`/Users/Shared/Developer/ai/city/math-code-projects/DeRham.jl/src/DeRham.jl`.
For `(n=2, d=5, p=7)`, precision came from the table with `r_m=[4,4]`,
`N_m=[4,4]`, and `M=7`. Module load was 25.220976 s, Fermat warm-up was
10.956747 s, and peak RSS was 3,341,221,888 bytes. The evaluator's real-server
`fs_init` connection took 0.000051 s. `bin/funsearch check` returned
`{"status":"OK","score":0,"sig":[0,0,0,0,0,0],"msg":""}` for the
configured pseudo-random p=7 seed and required mixed-reward instance. No search
run was started.

The alternative seed also passed the same p=7 check with status OK and score 0.
The launcher selected Python 3.11.15 because the system `python3` was 3.9.6
and could not import `tomllib`.
