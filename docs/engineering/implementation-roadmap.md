# Implementation Roadmap

This continues `language-server-roadmap.md` (milestones M1–M8: protocol correctness, the
diagnostics engine, code actions, outline, references and rename, workspace, performance,
ergonomics; all done). The order below follows the audit's evidence (`language-intelligence-audit.md`)
and the priorities P0–P4 used in `feature-matrix.md`.

Each milestone is a vertical slice with the same parts:

* a reproduction;
* the shared semantic change;
* the feature wiring;
* in-process and JSON-RPC tests that fail on the previous build;
* updated docs.

## Done in this round

| # | Milestone | Content | Evidence |
|---|---|---|---|
| S1 (P0) | **Semantics for unfinished code** | `Document:ensure_semantics` type-checks the recovered AST for queries; diagnostics remain staged; the file's report entries are dropped when a check fails, so no stale positions are served | `tests/completion_context_test.lua`: 11 server-level tests failed on `498f664`; all pass now |
| S2 (P1) | **Context-aware completion** | `analysis/semantic.tl` (scope walk with positions, type-declaration detection, token-based expression keys); `analysis/completion.tl` (context classification, valid candidates, tiers). Covers member, method, scope, type and qualified-type positions, record constructors, blockers, ranking, and no duplicate parentheses. A speculative parenthesized check finds generic and overloaded call results | Same file plus `completion_test` (a former expected failure now passes) and `ergonomics_test` |
| S3 (P1) | **Signature help on the shared callee query** | The callee is located on tokens (`expression_key`) and typed through `type_of_expression`, so unfinished, nested and higher-order calls work | `completion_context_test` "signature help on unfinished and higher-order calls" |
| S4 (P1) | **Expected-type completion of enum values in strings** (was N1) | `literal_context` classifies the string's position: argument, declaration, assignment, comparison or constructor field. The expected type comes from tl's report, using declared types for assignment targets, where tl records the assigned value instead. Also fixes F7: tl's parser inserted tokens into the server's token list | `completion_context_test`: literal and token-list tests fail on `44941bb` |

| S5 (P2) | **One classifier for definition and references** (was N2) | Definition asks `references.resolve_target` and the new `references.declarations` first, with full name ranges; methods give both their declaration and their implementation | `navigation_agreement_test` fails on `e682270` |

| S6 (P1) | **Documentation comments in hover** (was N3) | `semantic.doc_comment` reads the comment block that tl's lexer attaches to the declaration's first token; the declaration comes from `references.declarations` | `tests/hover_docs_test.lua` |

Suite after S1–S6: **155 tests, 152 passed, 0 failed, 3 expected failures** (baseline: 131 / 127 / 0 / 4).

## Next (in priority order)

### N3 (P1): documentation in completion items

Hover shows declaration comments (S6). Completion items could carry them too, through
`completionItem/resolve` so that the list stays cheap: the item's `data` holds the candidate's
declaration, as typescript-language-server's `cacheId` does.

### N4 (P2): cross-file references and rename for exported fields

Today, references for globals and fields cover open files only. Plan:

1. Use the workspace index to pre-filter files whose tokens contain the name. This is cheap: lex
   only, as TypeScript's name table does.
2. Type check only those files in a temporary env.
3. Confirm each hit by identity with the existing resolver, as rust-analyzer's `FindUsages` does
   (text search, then semantic confirmation).
4. Rename must stay refused when a candidate file fails to check.

* Risk: medium (cost, env isolation).
* Measure with `scripts/bench_latency.lua`, extended to a multi-file workspace.

### N5 (P2): auto-import completion

* Depends on N4's module/export index.
* Offer exported names of workspace modules not yet required.
* The edit inserts `local m = require("…")` after the existing requires. It is applied only when
  the name is not already bound in scope; check this with `semantic.visible_symbols`.

### N6 (P4): scale

* Measure a multi-file workspace (dependency edits re-check every open document today).
* Candidate improvement: re-check only `dependents_of(path)` instead of the whole env.
* This needs care, because tl caches module types in `env.modules`. A dependency's new type must
  replace the cached one without rebuilding the env. That requires an explicit invalidation rule:
  drop the module and its transitive dependents from `env.modules` / `env.loaded`. Verify with the
  existing unsaved-dependency tests plus a test where an exported type changes.
* Do this only with before/after numbers.

### Blocked on tl (proposals in the audit, §6)

* Constraint of a type variable (`T is R`): the remaining completion expected-failure test.
* Single-value call results in `by_pos`: would remove the speculative check.
* Type-declaration flag in the report.
* Enum member positions and type-name uses: needed for type renames and enum navigation.

## Rules for every milestone

* tl stays the semantic authority. No inferred types in the server; on a miss, return nothing.
* No new abstraction without a test that needed it.
* Regression tests must fail on the previous build. Check this with `git archive HEAD` and a separate tree.
* Measure hot-path changes with `scripts/bench_latency.lua`.
