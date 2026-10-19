# Teal Language Server — Gap Analysis

Audit date: 2026-10-18. Baseline: `teal-language-server` 0.2.1 (commit `ec1aaa3`),
`tl` 0.24.8, Lua 5.4. Reference: the local `eslint` checkout (read-only).

Everything marked *verified* was reproduced against the running server or the `tl`
library. Claims about absent features were checked against the handler registry
(`set_handler` calls) and the advertised `capabilities` table.

## 0. Environment and baseline

| Item | Finding |
|---|---|
| Language | Teal (`src/**/*.tl`), compiled to Lua in `gen/` with `cyan build` (`tlconfig.lua`). Both trees are committed. CI fails if `gen/` is stale. |
| Build | LuaRocks `builtin` (`teal-language-server-0.2.1-1.rockspec`). Each module is listed explicitly. The bundled `tree-sitter-teal` C parser is compiled into `teal.so`. |
| Runtime | `luv` event loop plus `lusc` structured concurrency, all on one thread. `ltreesitter` provides the syntax tree used for cursor context. |
| Tests | `tested` integration tests in `tests/`. They spawn the installed `teal-language-server` binary over stdio (`tests/helpers/lsp_client.lua`). |
| Baseline result | **63 tests: 59 passed, 4 expected-failures, 0 failed** (about 9 s). |
| Test dependency bug | The rockspec says `tested >= 0.3.0`. Releases 0.4.0 and 0.5.0 replaced the module-level API (`tested.test`, `tested.before`) with a class API, so `luarocks test` on a fresh tree fails before running any test (*verified*). The tests only run with `tested 0.3.0`. |

## 1. Already implemented and working

* **Document sync**: `didOpen`, `didChange` (full sync), `didSave`, `didClose`.
  Each change re-lexes, re-parses and re-type-checks the buffer and republishes diagnostics.
* **Diagnostics**: lexer, parser and type errors, plus compiler warnings, from `tl.check`.
  `tlconfig.lua` options `disable_warnings` and `warning_error` are honoured.
  `.lua` files are checked in lax mode.
* **Hover** on identifiers, built from the `tl` type report:
  * `by_pos` lookup first, then a fallback that resolves a token chain;
  * records, enums, functions and poly-functions are formatted as markdown.
* **Completion**:
  * fields after `.` and methods after `:` (`self`-aware);
  * method chaining via `by_pos` with return-depth following;
  * string methods; enum keys of map types.
* **Signature help** after `(`, including overloads (POLY).
* **Go to definition** (the symbol's declaration site) and **go to type definition**.
  Both work across files for record and function fields.
* **Project config**: `tlconfig.lua` with `include_dir`, `source_dir` and `global_env_def`.
  The Lua `package.path` is discovered from a workspace-local `*/bin/lua` (luarocks trees).
* **Env rebuild on save**: debounced by 100 ms; re-checks every open document afterwards.

## 2. Implemented but incomplete

| Area | Gap | Evidence |
|---|---|---|
| Completion while typing identifiers | `handler_helper.get_node_info` returns `nil` whenever `context.triggerKind ~= TriggerCharacter`. VS Code and Neovim send `triggerKind = 1` (Invoked) while you type an identifier or press Ctrl-Space, so **scope completion never fires in real editors**. The tests pass only because they omit `context`. | *Verified*: an Invoked request on `local x = ma` returns `null`. |
| Position encoding | Every column is a **byte** offset: tl `x`, tree-sitter columns, and `#node_info.source`. LSP requires UTF-16 code units by default. | *Verified*: in `local s = "héllo" local n: number = "x"`, the `n` diagnostic is reported at character 25; the correct UTF-16 value is 24. |
| Request error handling | `LspEventsManager:_trigger` catches handler errors but sends no response, so the client waits forever. Unknown request methods (`documentSymbol`, `references`, …) also get no response, although the spec requires `MethodNotFound`. | *Verified*: a `textDocument/documentSymbol` request timed out with no reply. |
| Diagnostics payload | No `source`, `code` or `tags`. Lex errors have a zero-width range and the generic text "Unexpected token". Ordering is not deterministic (warnings come before errors and are not sorted). | Code: `analysis/document.tl` `process_and_publish_results`. |
| Config errors | An invalid `tlconfig.lua` raises an error inside the `initialize` handler. Combined with the missing error response above, the editor hangs at startup instead of getting a message. | Code: `server_state.tl` `_load_config` → `asserts.fail`. |
| Cross-file analysis | `require` resolution reads modules **from disk**, caches them in the shared `env.modules`, and only rebuilds on `didSave`. Unsaved edits in an imported module are invisible to its importers, and dependents only refresh after a save. | Code: `tl.require_module`, `env_updater.tl`. |
| Hover range | The range starts at the cursor position, not at the token start. | Code: `language_features.tl` `_on_hover`. |
| Type report growth | All documents share one `TypeReporter`. Each re-check appends new type ids, and `env.loaded_order` gets one entry per check, so memory grows with every keystroke. | *Verified*: 200 checks of a 5-line file took the type table from 638 to 1235 entries and `loaded_order` from 3 to 202. |

## 3. Missing features (no handler registered, no capability advertised)

* `textDocument/codeAction`: no quick fixes or fix-all.
* `textDocument/documentSymbol` and `workspace/symbol`.
* `textDocument/references`, `textDocument/rename` and `prepareRename`.
* `textDocument/formatting`. The `tl` 0.24.8 library has no formatter; `tl.pretty_print_ast` regenerates code and drops comments.
* `textDocument/documentHighlight`, inlay hints, semantic tokens.
* Lint rules beyond the compiler's warnings: no rule ids, no per-rule severity, no options, no suppression comments.
* Completion details: no `detail`/`documentation`, no `require("…")` module-path completion. Keywords are not offered.
* `$/cancelRequest` is ignored. The server processes requests serially anyway.

## 4. Architectural problems

1. **No diagnostics pipeline.** `Document:process_and_publish_results` mixes lexing, parsing,
   type checking, warning filtering and LSP serialization. Rules, suppression and code actions need
   a single intermediate representation: a problem with rule id, severity, range and optional fix.
2. **No position abstraction.** Conversions between 1-based byte columns (tl), 0-based byte columns
   (tree-sitter) and 0-based UTF-16 (LSP) are done inline as `x - 1` or `pos.character - 1`, in more than 20 places.
3. **One global type report for all files.** It works because `by_pos` and `symbols_by_file` are
   keyed by file, but globals leak between documents, and the report grows without bound (see §2).
4. **Request dispatch has no response contract.** A handler must call `send_rpc` on every code path.
   Forgetting to, or raising an error, leaves the client hanging.
5. **Cursor context comes from tree-sitter strings, then is re-resolved through dotted strings**
   (`split_by_symbols`). This approximates the compiler's own `by_pos` data and fails for
   computed expressions. Newer code paths already prefer `by_pos`, and that direction should continue.

## 5. Features limited or blocked by the compiler (`tl` 0.24.8)

| Feature | Limitation |
|---|---|
| References / rename across files | The type report records symbol *declarations* (`symbols_by_file`) and *types at positions* (`by_pos`), but it does not record which declaration an identifier use refers to. References must be rebuilt from scope walks (feasible within one file) or by identity of the `by_pos` type id (feasible for record fields, ambiguous for primitives). |
| Generic return type variables | `first<T>(...): T` records the declaration-site `T` without its instantiation. This is the cause of the existing expected-failure tests. |
| Formatting | There is no comment-preserving formatter in the toolchain. |
| Incremental parsing | `tl.parse` has no incremental mode. tree-sitter does, but the server re-parses from scratch. Files are small enough that this is acceptable. |
| Callback parameter inference | Unannotated parameters are always `any`; contextual typing does not apply (*verified*: `table.sort(t, function(a, b) …)`). This makes an `implicit-any` lint rule reliable. |
| Unused, shadowing and duplicate-key warnings | **Already emitted by the compiler** (`unused`, `unread`, `redeclaration` warnings and the "redeclared key" error). Lint rules must not duplicate them; the server should label them and attach fixes instead. |
| Unreachable code, self-assignment, implicit `any` | **Not reported by the compiler** (*verified*). Each can be detected reliably from the tl AST. |

## 6. ESLint reference: concepts adopted, and what is deliberately not copied

From `eslint/lib` (rule engine `linter/linter.js`, `linter/file-report.js`, `linter/source-code-fixer.js`,
`linter/apply-disable-directives.js`, `rule-tester/rule-tester.js`):

* **Adopted**:
  * rule objects with `meta` (id, description, type, fixable, has-suggestions, default options) and a `create(context)` that returns node-kind listeners;
  * a context exposing `report`, `options`, source and type info;
  * severity normalization (`off`/`warn`/`error`, also `0`/`1`/`2`);
  * options deep-merged over `meta.defaultOptions`;
  * fixes as `{range, text}`. Overlapping fixes are skipped (single left-to-right sweep, as in `source-code-fixer.js`). Suggestions are never applied automatically;
  * `disable` / `disable-next-line` / `disable-line` comments with optional rule lists and a `--` justification;
  * deterministic ordering by line, then column;
  * a RuleTester-style harness with valid and invalid cases, including fix output checks.
* **Not adopted**:
  * flat-config file globbing and plugin package loading. Teal projects already have `tlconfig.lua`, so rules are configured inside it;
  * esquery selectors and code-path analysis. Listeners are keyed by tl node `kind`; no rule needs code paths;
  * JavaScript-specific rules.

## 7. Status after milestones M1–M8 (2026-10-18)

Every milestone in `language-server-roadmap.md` is implemented and covered by tests.
Suite: **131 tests, 127 passing, 4 expected failures**. The expected failures are pre-existing:
generic type-variable resolution in tl 0.24.8, and a definition on table-constructor keys.

Resolved from §2–§4:

* Invoked completion, UTF-16 positions, the request/response contract and config errors (M1).
* Diagnostics pipeline: one problem model, rule codes, deterministic order, rules, suppression, configuration (M2).
* Code actions and fix-all (M3).
* Outline, references, highlight and rename (M4, M5).
* Unsaved edits reaching importers, `workspace/symbol` and `require` completion (M6).
* Bounded type-report growth, debounced diagnostics and cancellation (M7).

Remaining limitations, all deliberate or caused by the compiler:

* **Cross-file references and rename cover open files only.** Files that are not open cannot be type-checked
  cheaply, and resolving a record field needs types. A rename of a field or global says so via `window/showMessage`.
  Rename refuses a table-constructor key whose table type cannot be determined, instead of producing broken code.
* **Type names cannot be renamed.** Uses in type annotations are type objects, not AST nodes, and the
  report does not record them.
* **Enum members have no positions** in tl's types, so in the outline they point at the enum.
* **No formatter.** `tl` 0.24.8 has none that preserves comments.
* **Full document sync.** tl has no incremental parser. Analysis is debounced instead.
* **Dependency edits rebuild the whole env.** Every open document is re-checked after a debounce. This is simple and
  correct, but its cost grows with the number of open documents.
* **Cancellation only applies to requests that have not started.** Handlers run synchronously on the single
  analysis task, so a request already being handled cannot be interrupted.
* Verified locally on Lua 5.4 only. CI runs 5.2–5.4.
