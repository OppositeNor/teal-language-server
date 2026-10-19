# Performance Baseline

All numbers on this page were **measured**. Nothing is estimated unless it says so.

## Method

* Script: `scripts/bench_latency.lua`. It drives the installed server over stdio JSON-RPC with
  `tests/helpers/lsp_client.lua`. The server runs **without `--coverage`**: the test suite enables
  luacov, which slows every request by roughly 100× (at 112 lines a request took ~700 ms with
  coverage and ~5 ms without).
* Workload: a synthetic, domain-neutral module of `n` records. Each record has 3 fields, a method
  with a loop, and a constructor function. The last line is edited.
* Each timed request follows a `didChange` to a new version. The request therefore includes the
  on-demand lex + parse + type check of the new text, which is what an editor sees while typing.
  30 iterations per scenario; P50 / P95 reported.
* Scenarios:
  * **open**: `didOpen` until the first `publishDiagnostics` (cold check).
  * **completion, broken**: the buffer ends in `local _ = p.`, so it does not parse.
  * **completion, valid**: `local _ = p.a`, with the cursor after the `.`.
  * **hover** / **definition**: on `p` in that line.
* RSS: `VmRSS` of the server process after the run.
* Environment:
  * Linux 7.2.11-arch1-1 x86_64, AMD Ryzen AI 9 HX 370;
  * Lua 5.4 (`/usr/bin/lua5.4`), tl 0.24.8;
  * one machine, no other load control.
* Before/after comparison:
  * "before" = commit `498f664`, exported with `git archive` and built into a separate LuaRocks tree;
  * "after" = the working tree right after milestone 2 (context-aware completion).

  Both ran back to back with the same script and client.

Reproduce:

```
export PATH=$PWD/luarocks_tree/bin:$PATH
lua5.4 -e 'package.path="luarocks_tree/share/lua/5.4/?.lua;"..package.path; package.cpath="luarocks_tree/lib/lua/5.4/?.so;"..package.cpath' \
    scripts/bench_latency.lua teal-language-server 30
```

## Results (ms, P50 / P95)

**Before (`498f664`)**

| lines | open | completion, broken buffer | completion, valid buffer | hover | definition | RSS (MB) |
|---|---|---|---|---|---|---|
|   112 |   8.7 | 1.5 / 2.7 | 5.6 / 11.1 | 5.7 / 9.4 | 5.8 / 7.7 | 23 |
|  1102 |  57.5 | 17.2 / 38.5 | 76.8 / 150.3 | 79.8 / 148.4 | 76.7 / 156.9 | 91 |
|  5502 | 369.9 | 105.8 / 620.0 | 568.8 / 693.2 | 506.7 / 644.3 | 524.9 / 658.0 | 211 |

**After (this work)**

| lines | open | completion, broken buffer | completion, valid buffer | hover | definition | RSS (MB) |
|---|---|---|---|---|---|---|
|   112 |   8.2 | 4.1 / 5.0 | 5.5 / 6.4 | 6.0 / 10.7 | 5.8 / 7.6 | 25 |
|  1102 |  57.9 | 59.0 / 151.0 | 75.3 / 167.9 | 88.3 / 151.7 | 79.6 / 163.0 | 107 |
|  5502 | 360.9 | 380.5 / 965.9 | 560.1 / 899.1 | 555.3 / 1126.1 | 569.6 / 1112.8 | 200 |

**After S5 (definition through the references classifier) and S6 (hover documentation)**, 2026-10-19

The first measurement of S5+S6 showed a regression (hover at 1102 lines: 134.5 / 209.3; at 5502:
879.9 / 1444.7). The resolver walked the whole AST in ast_walk's sorted order on every request, and
it built the outline eagerly. In-process profile at 1.1k lines:

| Stage | Time (ms) |
|---|---|
| index walk | 10.7 |
| outline | 13.4 |
| `tl.check` (for comparison) | 28.6 |

Fixed by:

* a per-AST index of parents and name nodes, built in one unsorted traversal and cached for the
  AST's lifetime. Verified to give the same parents as the sorted walk on 94 files / 146,537 nodes;
* building the outline only when a field target needs it.

| lines | open | completion, broken buffer | completion, valid buffer | hover | definition | RSS (MB) |
|---|---|---|---|---|---|---|
|   112 |  10.3 | 4.5 / 5.7 | 6.1 / 7.9 | 7.0 / 12.6 | 7.1 / 13.6 | 25 |
|  1102 |  61.6 | 65.7 / 159.2 | 90.3 / 156.1 | 101.9 / 192.8 | 97.8 / 198.7 | 100 |
|  5502 | 400.2 | 420.5 / 1092.1 | 598.2 / 1040.1 | 636.5 / 1197.7 | 645.8 / 1166.4 | 195 |

Absolute numbers drift by about 10% between runs on this machine; compare columns within one run.
Hover relative to valid-buffer completion at 1102 lines:

* first measurement: 88.3 / 75.3 = 1.17;
* now: 101.9 / 90.3 = 1.13.

The remaining hover/definition overhead is the index build on the first request after an edit.

**Workspace references (S8)**, 2026-10-19

A shared module `lib.tl` (record `Item` with field `weight`) and `n` closed files, each using
`weight` 20 times; only `main.tl` is open. One cold `textDocument/references` request (it type
checks the candidate files), then 5 warm ones (cached checks).

| closed files | locations | cold (ms) | warm P50 / P95 (ms) | RSS (MB) |
|---|---|---|---|---|
|   10 |  203 |  34.2 | 5.5 / 9.3 | 16 |
|   50 | 1003 | 157.6 | 31.8 / 42.2 | 44 |
|  150 | 3003 | 516.4 | 91.3 / 140.9 | 112 |

All uses were found (n × 20 + 3). The cold cost grows linearly, at about 3.4 ms per closed file of
41 lines, and stays within the default 1.5 s budget at 150 files.

**Module edit with many open documents (S10)**, 2026-10-19

An unsaved edit to an open module with one open importer, while `k` unrelated 331-line documents
are open. The time runs from `didChange` until the env rebuild and its re-checks are done (by
polling `teal/serverStats`). It includes the 150 ms diagnostics debounce and the 100 ms rebuild
debounce. Previous build `f4abd97` vs. S10, same script, back to back:

| unrelated open documents | before (P50 / max of 5) | after (P50 / max of 5) |
|---|---|---|
|  5 | 357.7 / 387.5 | 255.6 / 264.3 |
| 20 | 815.3 / 825.7 | 255.3 / 255.7 |

The previous build re-checked every open document (≈ 30 ms each). Now the cost is independent of
the number of unrelated documents: the remainder is the debounces.

## Reading the numbers

* **Valid buffers: no measurable change.** P50 differences are within run-to-run noise. The new
  completion pipeline is token-based and cheaper than the old tree-sitter walk, but the type check
  dominates.
* **Broken buffers: slower by design.** Before, a request on an unparsable buffer skipped type
  checking and returned nothing. Now it pays for one check of the recovered AST, about the same as
  a valid buffer, and returns the correct members. This is the cost of correctness, not a regression
  in an equivalent computation.
* **The dominant cost is the whole-buffer re-check.** At 5.5k lines, every request after an edit
  pays ~0.4–0.6 s at P50. The open cost (one check) is ~0.36 s. This existed before this work.
* **P95 outliers at the larger sizes** are consistent with the debounced diagnostics publish and the
  env rebuild that bounds type-report growth (`type_report_limit`, default 50,000 entries). Both run
  on the same task loop. Not investigated further.
* **The speculative check** (`Document:type_of_expression`) runs only when a call receiver misses in
  `by_pos`. It is not exercised by this benchmark. It costs one additional check of the buffer, and
  its result is cached per snapshot.

## What would reduce latency (not implemented; needs measurement first)

1. **Reuse a check across a burst of requests.** Already the case: one check per document version.
   The cost comes from editors sending a request after every keystroke on large files.
2. **Skip type checking for requests that need no types**: document symbols, `require` path
   completion, and completion blockers. A small win.
3. **Per-module checking.** tl checks a whole file. Splitting is not possible without upstream support.
4. **Cancel superseded on-demand checks.** tl's checker is synchronous and cannot be interrupted.
   It would need yield points in tl.

Targets have deliberately not been set. Measured here: at ≤ 1.1k lines, requests after an edit take
< 100 ms at P50. The size distribution of real Teal modules was not surveyed.
