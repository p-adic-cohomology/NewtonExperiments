# Consistent K-sample Newton experiment

This experiment is a separate evaluator from [`funsearch-newton`](../funsearch-newton/). A candidate generates `K` curves per evaluation, and the score rewards distinct Jacobian zeta functions across the batch. The older experiment and its data remain unchanged.

The default instance is p=7, K=16, and `near_dup=0.5`. The candidate interface, score, sample-token legend, and public constraints are described in [problem.md](problem.md).

Each run stores the shared evaluator index in `near-dup-index.jsonl` beside `curves.jsonl`. The server accepts `--near-dup-index PATH` to select another index path; check mode always uses a fresh temporary index.

Run checks or start an authorized search through the managed launcher in [server/README.md](server/README.md). Set `FUNSEARCH_NEWTON_SERVERS` to choose the number of single-threaded Julia score-server processes; it defaults to 2.

Novelty uses the same reference files as the original experiment: `experiments/funsearch-newton/reference/plane_quintic_newton_polygons.tsv` and `known_plane_quintic_newton_polygons.tsv`. The server loads both once at startup, so the novelty set stays fixed during a run.
