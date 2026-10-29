# Discovery journal

`discoveries.jsonl` records interesting curves and families that the
experiments in this repository have turned up: what was found, where it came
from, and what is still open. Entries are added only after the overseer
approves them.

Each line is one JSON object, one entry, in the order entries were accepted:

| Field | Type | Meaning |
|---|---|---|
| `id` | integer | Entry number, 1, 2, ... |
| `title` | string | Short descriptive title |
| `date` | string | Date the entry was accepted, `YYYY-MM-DD` |
| `status` | string | `open`, `explained` or `superseded` |
| `summary` | string | One or two sentences |
| `metadata` | object | Anything that pins down the setting: ambient space, degree, genus, primes, family, polygons |
| `provenance` | array | How we came to it: objects with `kind` (`funsearch-run`, `computation`, `literature` or `other`), `ref` and `note` |
| `data` | array of strings | Where the evidence lives: repository paths or bead ids |
| `caveats` | array of strings | Anything that limits confidence, e.g. computation precision |
| `description` | string | The family or curve, stated precisely |
| `observations` | array of strings | What was computed or found, with numbers |
| `explanation` | array of strings | What theory accounts for it, if anything, and how sure we are |
| `open_questions` | array of strings | What remains to be done |
| `references` | array of strings | Literature citations |

Conventions: curves are given by homogeneous equations in x, y, z. Newton
polygons are written as slopes with multiplicities, e.g. `1/4^4 1/2^4 3/4^4`,
and codimension means the codimension of the Newton stratum in A_g.
