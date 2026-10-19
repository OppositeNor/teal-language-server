# Language Intelligence Audit

Audit date: 2026-10-18. This audit follows `language-server-gap-analysis.md`, which covered the
ESLint-inspired diagnostics work (milestones M1–M8). This one looks at **semantic quality**:
whether completion, hover, navigation and rename give correct answers on real, often unfinished,
code. It traces code paths, not README claims.

Companion documents:

* `feature-matrix.md` — per-feature status.
* `semantic-architecture.md` — the shared semantic layer.
* `implementation-roadmap.md` — what comes next.
* `performance-baseline.md` — measurements.

## 1. Workspace and revisions

| Repository | Revision | Role in this work | License |
|---|---|---|---|
| `teal-language-server` | `498f664` (+ this work, uncommitted) | implementation target | MIT |
| `tl` | `c6b986e` (2026-10-08, `tl-dev-2`, modular `teal/` sources) | read-only reference; **the server runs tl 0.24.8 from LuaRocks**, not this checkout | MIT |
| `TypeScript` | `5237fd4689` — **the Go port (TS 7)**: `tsc/internal/ls/*.go`, `tsc/internal/lsp/server.go` | read-only reference | Apache-2.0 |
| `typescript-language-server` | `7b28f10` (6.0.2) | read-only reference (it talks to the JS tsserver) | Apache-2.0 (some files MIT) |
| `rust-analyzer` | `5ec20d044d` | read-only reference | MIT / Apache-2.0 |
| `eslint` | `8ffeb8c02` (10.13.0) | read-only reference for lint and fix integration (see gap analysis §6) | MIT |

No code was copied from the reference repositories. Only concepts were adapted, and they are
named below with their source paths.

`git status` of `teal-language-server` before this work: clean except for an untracked, empty
`PanGPA.log`, which was left untouched.

## 2. Build and baseline

* Toolchain: Lua 5.4 (`/usr/bin/lua5.4`), the LuaRocks tree in `luarocks_tree/`, `cyan 0.4.1`,
  `tl 0.24.8`, and `tested 0.3.0`. Releases 0.4+ of `tested` have an incompatible API.
* Build: `cyan build` (Teal → `gen/`), then `luarocks --lua-version 5.4 make --tree=luarocks_tree`.
  The default `lua` on this machine is 5.5, so `--lua-version 5.4` is required.
* Tests: `tested -n 0 tests/`, with `luarocks_tree/bin` on `PATH`. Integration tests spawn the
  installed server over stdio.
* **Baseline (before this work): 131 tests, 127 passed, 0 failed, 4 expected failures**, in about 72 s.
  `cyan build` reproduced `gen/` byte for byte, so `gen/` was in sync.

## 3. How a request flows today

```
stdin ─ lsp/stdin_reader, reader_writer ─ lsp/events_manager (queue, $/cancelRequest, error responses)
      ─ handlers/* (decode params, UTF-16 ⇄ byte positions, build LSP results)
      ─ analysis/document.tl (per buffer: tokens, AST, tl.Result, problems; tree-sitter tree)
      ─ tl 0.24.8: lex → parse_program → check (shared Env + shared TypeReporter)
```

* **Semantic authority**: `tl.check` on a shared `tl.Env`. With `report_types = true`, the env
  fills one shared `TypeReport`:
  * `by_pos[file][y][x]` — the type of the expression at a position;
  * `symbols_by_file[file]` — ordered declarations with `@{` / `@}` scope markers;
  * `types` — type information: fields, args, rets, ref;
  * `globals`.

  `docs/type_report_lookups.md` describes these lookups.
* **Syntax for cursor context**: tree-sitter (`tree-sitter-teal`, bundled). It is used only to
  find node shapes around the cursor. tl's own lexer tokens and AST are used for everything else.
* **Overlay**: `EnvUpdater:_install_open_document_overlay` wraps `tl.search_module`, so a `require`
  reads open buffers before the disk. A module edit in an open buffer schedules a debounced full
  env rebuild that re-checks every open document.

### Feature traces (protocol plumbing vs. semantic computation)

| Feature | Plumbing (adapter) | Semantic computation (before this work) |
|---|---|---|
| Completion | `handlers/language_features.tl:_on_completion` | Tree-sitter node at the cursor → receiver *source text* → `by_pos` key (`Document.bypos_key_for`), falling back to a dotted-name chain resolved through `tl.symbols_in_scope` + record `fields` |
| Hover | `_on_hover` | `by_pos` at the identifier (or its `.`), else the name chain; `lsp/formatter.tl:show_type` renders it |
| Signature help | `_on_signature_help` | lexer scan for the enclosing `(` and the comma count → callee type as for completion |
| Definition | `handlers/definitions.tl` | name → `Document:symbol_declaration_position` (scope walk); a field → the field type's declared position |
| References / highlight / rename | `handlers/navigation.tl` | `analysis/references.tl`: target identity is the *declaration position* (locals), the global name, or (record identity, field name) for fields. Uses are re-resolved through the same scope walk or the receiver's inferred type. Rename refuses what it cannot prove (types, stdlib, untypeable table keys). |

References and rename already use semantic identity (declaration positions and record identity)
rather than text matching. This matches the TypeScript and rust-analyzer approach: a name search
first, then semantic confirmation of each hit (`ls/findallreferences.go:getReferencesAtLocation`,
`ide-db/src/search.rs:FindUsages::search`).

## 4. Reference implementations studied

A trace with paths and symbols. Every path was checked to exist.

* **TypeScript (Go port).**
  * Completion: `tsc/internal/ls/completions.go`. `getCompletionData` takes the previous significant
    token (`getRelevantTokens`), then classifies the position:
    * right of a dot;
    * a new-identifier location (`computeCommitCharactersAndIsNewIdentifier`);
    * a blocker, such as a string, number or declaration name (`isCompletionListBlocker`).
  * It then collects member symbols (`getTypeScriptMemberSymbols`, filtered by
    `IsValidPropertyAccess`) or scope symbols (`getGlobalCompletions`, filtered by value vs. type
    meaning in `shouldIncludeSymbol`). Items are ranked by explicit `SortText` tiers:
    `LocalDeclarationPriority "10"`, `LocationPriority "11"`, … `GlobalsOrKeywords "15"`.
  * Incomplete code needs no special pass: everything runs on the error-tolerant AST and checker.
  * Hover: `ls/hover.go:ProvideHover`. Definition: `ls/definition.go`.
  * References: `ls/findallreferences.go`, with a name-table prefilter and then a semantic pass.
  * Rename: `ls/rename.go`. `renameBlockedReason` rejects library declarations.
  * Signature help: `ls/signaturehelp.go`, which counts argument commas on tokens.
* **typescript-language-server.** `src/lsp-server.ts` and `src/completion.ts` are a thin adapter.
  Items carry only a cache id in `data`; details, docs and auto-import edits come from
  `completionItem/resolve`.
* **rust-analyzer.**
  * Completion: `crates/ide-completion/src/context.rs:CompletionContext::new` re-parses a copy of the
    file with `COMPLETION_MARKER` (`"raCompletionMarker"`) inserted at the cursor. Syntax analysis then
    runs on a well-formed tree, while semantic queries map back to the original file.
  * `context/analysis.rs` classifies the position (`DotAccess`, path and type locations) and finds the
    expected type (`expected_type_and_name`). `item.rs:CompletionRelevance::score` ranks candidates.
  * Definitions and references share one classifier: `ide-db/src/defs.rs` (`NameClass` / `NameRefClass`).
  * Rename: `ide-db/src/rename.rs` rejects non-local or builtin definitions.
  * State: VFS overlays (`crates/vfs`) feed salsa inputs, requests run on immutable snapshots, and
    stale work unwinds with `Cancelled`.

**Transferable ideas used in this work:**

1. Classify the position from the previous significant token before doing any semantic work.
2. Make semantic analysis work on unfinished code instead of giving up on it.
3. Answer from the checker's own data, never from text heuristics presented as types.
4. Rank in explicit, deterministic tiers.
5. Do not insert syntax that already exists. rust-analyzer omits parentheses when a call follows.

**Not adopted:**

* salsa or another incremental query engine;
* a second parser or checker;
* macro-expansion machinery;
* tsserver's project graph.

None is justified by Teal's file sizes or by the measurements in `performance-baseline.md`.

## 5. Findings

### F1 (critical): semantic features went silent while the buffer did not parse

`Document:get_problems` ran `tl.check` only when lexing and parsing succeeded, and every request
handler used that cache. A buffer that does not parse is the normal state at the moment the user
types `p.`. The type report then held either nothing or **the previous version's positions**.
That stale data could be presented as the answer.

Reproduction (`probe` before the fix, all in an otherwise valid file):

| Case | Before | After |
|---|---|---|
| `local q = p.` at the end of the file | 0 items | `len, name, x, y` |
| `pt.` / `pt:` inside a function body | 0 / 0 | fields+methods / `len` only |
| a local declared in the same unsaved edit, then `brandnew.` | 0 | its record's fields |
| `make().` (a call receiver) | 0 | fields |
| nested `a.b.` | 0 | inner record fields |
| `self.` in a method | 0 | fields + methods |
| hover on `p` while a later line is unfinished | no type | `Point` |

tl's parser recovers from syntax errors, and `tl.check` on the recovered AST produces correct types
for the parsed parts (verified: `pt.` records `Point` at `pt`). This was fixed by checking the
recovered AST for semantic queries while still reporting only syntax errors as diagnostics
(`Document:ensure_semantics`). See `semantic-architecture.md` §2.

### F2 (high): receiver taken from the wrong node in tree-sitter error trees

For `local _ = b.item:` (with `item: string`), the `:` landed in a top-level `ERROR` node. The
receiver was then taken from the *start* of the previous statement's expression list (`b`), and
the completion offered `Box` members (`get`) instead of string methods. Tree-sitter error shapes
vary too much to locate receivers from them reliably.

Fix: the receiver is located on tl's lexer tokens (`semantic.expression_key`) by walking back over
the postfix expression. It is then mapped to where tl records that expression's type (name: at the
name; `e.f` / `e:f`: at the operator; `e[k]`: at `[`; `(e)`: at `(`; a call: callee plus one return
level).

### F3 (high): generic and overloaded call receivers

tl does not record call results, because they are tuples. Following the callee's `rets[1]` fails
for generic callees: the declaration-site `T` is reported uninstantiated. It also fails for
overloaded callees (POLY). Previously this was an expected-failure test.

Fix: on a miss for a call receiver, the server type-checks a **speculative copy** of the buffer
with that expression parenthesized, under a separate file name. It reads tl's own instantiated type
at the `(` and then removes the copy's entries from the shared report. This is rust-analyzer's
"modify a copy, analyze, map back" idea (`COMPLETION_MARKER`), applied to the checker instead of the parser.

### F4 (medium): completion candidates were not position-aware

* Type annotations (`local x: |`, `(a: |`, `): |`, `as |`, `is |`) got either nothing or the
  value-scope list. Now they get type names: types declared in visible scopes, the primitive types,
  and global enums and interfaces.
* `local function |`, `for i|`, numbers, comments and unterminated strings now get nothing, matching
  TypeScript's completion blockers and new-identifier locations.
* Scope completion had no `sortText`, so editors sorted locals, globals and keywords
  alphabetically together. Now the order is locals (tier 10), then globals (15), then keywords (17).
* `.` member completion ranks fields first, then plain functions, then `self` methods (which are
  normally called with `:`).
* Function snippets were inserted even when a call already followed (`v:|scale(2)` became
  `scale(factor)(2)`). Now the bare name is inserted in that case.

### F5 (medium, open): identity by name in `:` method filtering

tl leaves some `self: R` parameter types as an unresolved nominal (no `ref`), so `:` completion
matches the first parameter to the receiver by type *name*. Two different records with the same
name in different scopes could be confused. This is pre-existing behavior, now documented in code.

### F7 (high): the parser rewrote the server's token list

When it recovers from an error such as an unterminated call `f("o`, `tl.parse_program` *inserts
synthetic tokens* (here a `)` of kind `keyword`) into the token array it is given. The Document
passed its cached tokens. As a result, every token-based query that ran after a syntax error saw
tokens that are not in the text: completion context, signature help, references and lint rules.
Found while implementing string-literal completion: the cursor appeared to follow a `)`.

Fix: `ast_walk.parse_program` parses a copy of the list. All five call sites use it: Document,
speculative check, linter, workspace index, navigation. A regression test checks that the caller's
list is unchanged.

### F6 (open): cross-file navigation scope

References and rename for globals and record fields cover open files only. Teal has no cheap
cross-file index of uses without type checking each file. The workspace index
(`workspace_index.tl`) holds outlines only. Details: `feature-matrix.md`.

## 6. What `tl` exposes, and what would need upstream work

| Need | Status in tl 0.24.8 |
|---|---|
| Types at positions, declarations and scopes, record fields, function args/rets | **Exposed**: `TypeReport` (`by_pos`, `symbols_by_file`, `types`, `globals`) |
| Semantics of unfinished code | **Exposed in practice**: `tl.parse_program` recovers from errors, and `tl.check` accepts the recovered AST. This is not documented as a contract, so the server wraps it in `pcall`. |
| Instantiated type of a call result | **Recoverable**: tl records parenthesized expressions, so the server uses a speculative check. Ideally upstream would record single-value call results in `by_pos` (proposal below). |
| Is a declaration a type or a value? | **Recoverable through the AST** (`local_type` / `global_type` nodes). The report collapses `typedecl` into the declared type. |
| Use → declaration links (references) | **Recoverable** by scope walks. Not recorded by tl. |
| Parameter names of function *types* | **Recoverable** from tokens (`Document:_function_type_arg_names`). Not in the report. |
| Constraint of a type variable (`T is R`) | **Needs a modest upstream API.** `TypeInfo` for a type variable has no constraint field. This is the remaining expected-failure test. |
| Positions of enum members, uses of type names in annotations | **Need upstream changes.** They are not recorded. |
| Incremental parsing or checking | **Not available.** The server re-checks the whole buffer, which is affordable at current sizes (`performance-baseline.md`). |

### Upstream proposal (separate from this work; `tl` was not modified)

1. **Record single-value call results in `by_pos`.**
   * Query: the type of `f(x)` at the `(` of the call, when the call yields exactly one value.
     Store `t.tuple[1]` instead of skipping the tuple.
   * Guarantee: the stored type is the instantiated return type the checker used for the
     surrounding expression.
   * Tests: `first(items).name` (generic), overloaded `f("a").x`, `obj:m():n()`.
   * Benefit: removes the speculative re-check (F3).
2. **Constraint of a type variable in `TypeInfo`.**
   * Add `constraint: integer` for `TYPE_VARIABLE` entries.
   * Test: completion on `first(xs).` inside `function use<T is R>(xs: {T})` offers `R`'s fields.
3. **Mark type declarations in the report.**
   * Add a flag on the symbol, for example a 5th element, or a separate `typedecl` typecode for
     symbols that declare types.
   * Benefit: type-position completion would not need the AST walk.
