# Semantic Architecture

How language features get their answers, and the rules that keep those answers correct. The
diagnostics pipeline (problems, rules, suppression, fixes) is described in
`language-server-roadmap.md` and is unchanged by this work.

## 1. Layers

```
LSP client
  │ JSON-RPC over stdio
  ▼
lsp/*               transport, request/response contract, cancellation of queued requests
handlers/*          decode params, UTF-16 ⇄ byte positions, build LSP results (no semantics)
  ▼
analysis/completion.tl   completion context, candidates, ranking        (no LSP types)
analysis/references.tl   symbol identity, references, rename plans      (no LSP types)
analysis/symbols.tl      outline                                        (no LSP types)
analysis/semantic.tl     shared queries: scopes, expression keys, types (no LSP types)
  ▼
analysis/document.tl     per-buffer snapshot: text, version, tokens, AST, tl.Result,
                         tree-sitter tree, problems; ensure_semantics, type_of_expression
  ▼
tl 0.24.8                lexer, recovering parser, checker, TypeReport (the semantic authority)
```

The diagnostics engine (`analysis/diagnostics/*`) sits beside the feature modules and consumes the
same `Document` snapshot.

Rules:

* **tl is the only semantic authority.** The server does not infer types. Its helpers *locate* where
  tl recorded an answer, using `by_pos`, `symbols_by_file` and `types`.
* **No LSP types below `handlers/`.** The feature modules take tokens, AST and report, so they can
  be tested in-process (`tests/completion_context_test.lua`, `tests/rules_test.lua`).
* **Tree-sitter is a syntax hint only.** It classifies a position as comment, string, type or
  field name (`Document:syntax_hint_at`), which tl's tokens cannot tell cheaply. Receivers, scopes
  and types never come from tree-sitter text.

## 2. Snapshots and semantic freshness

A `Document` holds one version of one buffer. Its cache (tokens, AST, result, problems, type
positions, speculative results) is cleared when the text changes (`update_text`) and when the env
is rebuilt (`EnvUpdater`).

`Document:ensure_semantics()` brings semantic data to the current version:

1. lex and parse (tl's parser recovers from syntax errors);
2. run `tl.check` on that AST **even when it has syntax errors**, inside `pcall`;
3. if the check raises, remove this file's `by_pos` and `symbols_by_file` entries from the shared
   report, so no query can answer from an earlier version.

Diagnostics stay staged as before: lex errors, else parse errors, else type errors, warnings and
lint rules. Type errors of a recovered parse are mostly follow-on noise, so they are not published.
Semantic queries and diagnostics read the same snapshot.

The parser always runs on a **copy** of the token list (`ast_walk.parse_program`). When it
recovers from errors, tl inserts synthetic tokens into the list it is given, and the server's
tokens must stay exactly what the lexer produced.

Invariant: **after `ensure_semantics`, every `by_pos` / `symbols_by_file` entry for the file
describes the current text, or there is none.** tl replaces `by_pos[file]` at the start of each
check (`TypeReporter:get_collector`) and `symbols_by_file[file]` at its end (`store_result`).

Every request handler goes through `handler_helper.get_document`, which calls `get_problems` and
therefore `ensure_semantics`. Requests never wait for the debounced diagnostics, and they never see
stale types.

### Recovered results

`Document:is_recovered()` reports whether the current semantic data came from a text with syntax
errors. Types of the parsed parts are real checker output. Code that the parser skipped has none,
so queries there return nothing; they do not guess.

## 3. Shared queries (`analysis/semantic.tl`)

| Query | Input → output | Used by |
|---|---|---|
| `resolve(report, id)` | type id → `TypeInfo`, following NOMINAL `ref`s | everything |
| `visible_symbols(report, file, y, x)` | position → names visible there, innermost first, with declaration position and scope depth (mirrors `tl.symbols_in_scope`, keeping positions) | scope and type completion |
| `type_declaration_positions(ast)` | AST → set of `"y:x"` of names declared as types (`local_type` / `global_type`) | type-position completion, item kinds |
| `expression_key(tokens, last)` | token index → where tl records that postfix expression's type: name at the name, `e.f`/`e:f` at the operator, `e[k]` at `[`, `(e)` at `(`, a call as callee + one return level | member completion |
| `type_at_key(report, file, y, x, ret_depth)` | key → `TypeInfo`, or nil when tl recorded nothing or the return is a bare type variable | member completion |
| `enclosing_call(tokens, y, x)` | position → the innermost call's `(`, active argument index, whether it is a `:` call | signature help, literal completion |

Caveat: at an **assignment target**, `by_pos` holds the assigned value's type, not the target's
declared type. Literal completion therefore resolves `x = …` / `t.f = …` targets through
declarations (the scope walk plus record fields).

`Document:type_of_expression(key)` adds one fallback on top of `type_at_key`. When a key that
contains a call misses, it type-checks a **speculative copy** of the text with the expression
parenthesized, under the file name `<path>#speculative`. tl records the instantiated type of a
parenthesized expression at its `(`. The copy's report entries and `env.loaded` entry are removed
right after, and results are cached per snapshot. Buffers over 512 KiB skip the fallback.

### Symbol identity

| Symbol | Identity | Validity |
|---|---|---|
| local / parameter | file + declaration position (from `symbols_by_file`) | one snapshot of that file |
| global | name | one env (rebuilt on save and on dependency edits) |
| record field / method | (record identity = declaration position of the record type, field name) | one env |
| type name | declaration position | one snapshot (rename refused, see the feature matrix) |

Identities are **not stable across edits**. A position-based identity is recomputed from the
current snapshot on every request, and nothing holds an identity across versions.

## 4. Completion pipeline (`analysis/completion.tl`)

1. **Context** (`completion.context`): uses the token before the cursor, after skipping the
   identifier being typed, plus the tree-sitter hint.

   | Situation | Context |
   |---|---|
   | `e.` / `e:` | member access |
   | annotation colon (`local a:`, a parameter `(a:`, `): `), `as`, `is`, or a type node | type |
   | `local` / `global` | declaration (the keywords `function`, `record`, … only) |
   | `local function`, `for`, a record field name, a number, a comment, a string, a lexer error | none |
   | anything else | scope |

   Inside a quoted string, the context is a **literal** when its expected type has a known source:

   | Token before the string | Expected type |
   |---|---|
   | `(` / `,` of a call | the callee's parameter |
   | `=` | the declared target, or a constructor field |
   | `==` / `~=` | the other operand |

   Only enum values (of an enum, or of every enum in a union) are offered. The edit replaces the
   string's content.

   An annotation colon is told apart from a method access by token shape: a declared name after
   `local` or `global`, a parameter inside a definition's parameter list, or a `)` that closes such
   a list.
2. **Receiver** (member access only): `expression_key`, then `Document:type_of_expression`. A plain
   name chain (`a.b.c`) that tl did not record falls back to the scope walk plus record fields,
   which is still tl's data. Anything else gives no members.
3. **Candidates**, filtered for validity:

   | Access | Candidates |
   |---|---|
   | `:` | only functions whose first parameter is `self` or the receiver's type (POLY: any overload) |
   | `.` | all fields; maps with enum keys give the enum values |
   | strings and enums | string methods |
   | a type position | visible type declarations, primitive types, global enums and interfaces; after `m.`, only nested types |

4. **Ranking**: `sortText = "<tier>_<label>"`, so the order is deterministic.

   | Tier | Candidates |
   |---|---|
   | 10 | locals and fields |
   | 11 | plain functions and primitive types |
   | 12 | `self` methods after `.` |
   | 15 | globals |
   | 17 | keywords |

   Clients do their own fuzzy filtering on the prefix.
5. **Items** (`handlers/language_features.tl`):
   * kind from the candidate kind (records → Class, enums → Enum, interfaces → Interface);
   * `detail` = tl's type string;
   * a signature in `documentation`;
   * snippet arguments only when the client supports snippets **and** no `(` follows the cursor.

   `completionItem/resolve` is not used: items are cheap to build at current sizes.

## 5. Concurrency and cancellation

All analysis runs on the single lusc task loop. tl keeps global state (one env, one reporter), so
there is no parallel checking. `$/cancelRequest` drops queued requests. A request that has started
runs to completion; requests are short (see `performance-baseline.md`).

## 6. Deliberately not built

* **A query or incremental engine (salsa-like).** Whole-buffer re-checks take milliseconds at
  realistic sizes, and tl has no incremental API.
* **A second parser or type checker.** Tree-sitter is limited to syntax hints.
* **Speculative checks for every request.** They are used only when tl's report lacks the answer
  for a call receiver.
