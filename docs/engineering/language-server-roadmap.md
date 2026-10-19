# Teal Language Server — Target Architecture and Roadmap

This plan builds on the gap analysis in `language-server-gap-analysis.md`. It extends the existing
server step by step and does not replace it. The `tl` compiler remains the only source of
syntax and semantic truth. tree-sitter is used only to find the cursor context in incomplete code.

## Target architecture

```
                 ┌──────────────────────── LSP protocol adapter ────────────────────────┐
 stdin/stdout ── │ reader_writer · events_manager (request/response contract, errors,   │
                 │ MethodNotFound, cancellation) · position encoding (UTF-16 ⇄ bytes)   │
                 └───────────────┬──────────────────────────────────────────────────────┘
                                 │ handlers/* (thin: decode params → call provider → encode)
   ┌─────────────────────────────┼─────────────────────────────────────────────┐
   │ Language feature providers  │ completion · hover · signature · definition │
   │                             │ symbols · references/rename · code actions  │
   └─────────────────────────────┼─────────────────────────────────────────────┘
                                 │
   ┌──────────── Diagnostics engine (analysis/diagnostics/*) ───────────┐
   │ compiler problems (tl errors/warnings, labeled with codes)         │
   │ lint rules (rule registry, meta, options, AST listeners by kind)   │
   │ suppression directives · severity config · ordering · fixes        │
   └──────────────────────────────┬─────────────────────────────────────┘
                                  │
   ┌── Document (per buffer) ─────┴───── cache: tokens, AST, tl.Result, problems ──┐
   │ DocumentManager · EnvUpdater (tlconfig.lua, package.path, debounced rebuild)  │
   └───────────────────────────────────────────────────────────────────────────────┘
```

Key decisions:

* **One problem representation.** Every diagnostic, whether from the compiler or a rule, becomes a
  `Problem {rule_id, severity, message, range (tl 1-based byte coordinates), fix?, suggestions?, tags?}`.
  Conversion to LSP (UTF-16, 0-based) happens only at the protocol edge.
* **Configuration stays in `tlconfig.lua`.** Teal projects already have this file. The existing
  `externals` table exists so tools can add settings there without breaking `tl` or `cyan`:

  ```lua
  return {
     source_dir = "src",
     externals = {
        teal_language_server = {
           rules = {
              ["unreachable-code"] = "warn",
              ["implicit-any"] = { "error", { allow_in_lua = true } },
              ["self-assignment"] = "off",
           },
        },
     },
  }
  ```

  Compiler warnings keep using tl's own `disable_warnings` / `warning_error` keys.
* **Suppression comments** follow the ESLint directive semantics, renamed to `tls-`:
  `-- tls-disable-next-line <rule>[, <rule>] [-- reason]`, `-- tls-disable-line`, and
  `-- tls-disable` / `-- tls-enable` for blocks. Compiler warnings are addressed as `tl/<tag>`, for example `tl/unused`.
* **No concurrency inside the compiler.** `tl` keeps global state (the stdlib env and the shared reporter).
  All analysis stays on the single lusc task loop. Responsiveness comes from caching and debouncing, not threads.

## Milestones (priority order)

| # | Milestone | Content | Status |
|---|---|---|---|
| M1 | **Protocol correctness** | Error responses for failing handlers; `MethodNotFound` for unknown requests; UTF-16 ⇄ byte position conversion for all requests and diagnostics; completion on `Invoked` trigger; an invalid `tlconfig.lua` reported via `window/showMessage` instead of hanging; pin `tested` to the compatible API. | **Done** — `tests/protocol_test.lua` |
| M2 | **Diagnostics engine + rules** | Problem model; compiler problems labeled `source = "teal"` with `code = tl/<tag>`; deterministic ordering; `Unnecessary` tag on unused-variable warnings and unreachable code; rule registry with meta and options; rules `unreachable-code`, `self-assignment` and `implicit-any`; suppression directives; config via `externals.teal_language_server.rules`; RuleTester-style unit tests. | **Done** — `tests/rules_test.lua`, `tests/diagnostics_test.lua` |
| M3 | **Code actions** | `textDocument/codeAction` with quick fixes from problem fixes and suggestions. Compiler-warning fixes: prefix an unused variable with `_`, remove an unused `require`. "Disable rule for this line" for every problem. `source.fixAll.teal` using non-overlapping fixes. Version-checked `WorkspaceEdit`. | **Done** — `tests/code_action_test.lua` |
| M4 | **Document symbols** | Outline built from the tl AST: records, interfaces, enums, functions, methods, locals at top level. | **Done** — `tests/document_symbol_test.lua` |
| M5 | **References + rename (open files)** | Built from `symbols_by_file` scopes and identifier resolution. Rename validates identifiers and refuses keywords and cross-file symbols. | **Done** — `tests/references_test.lua` (fields across open files, typed table-constructor keys; rename refuses types, stdlib globals and untypeable constructor keys) |
| M6 | **Workspace model** | Overlay open buffers on `require` resolution so unsaved edits reach importers; dependency graph from `Result.dependencies` for targeted invalidation; `workspace/symbol`; `require("…")` module-path completion. | **Done** — `tests/workspace_test.lua` (index refreshes lazily by mtime, so no file watcher is needed; includes an end-to-end test of a `.d.tl` declaration module) |
| M7 | **Performance** | Bound the shared type report's growth; debounce `didChange` analysis; honour `$/cancelRequest` for queued requests. | **Done** — `tests/performance_test.lua` (shared reporter kept, bounded by an env rebuild past `type_report_limit`; debounced publishing with on-demand checks for requests; reader/processor queue for cancellation; `teal/serverStats` request) |
| M8 | **Ergonomics** | Completion `detail`/`documentation` (types, signatures), snippet arguments, keyword completion, inlay hints for inferred local types. | **Done** — `tests/ergonomics_test.lua` (plus parameter names for functions declared as record fields, e.g. in `.d.tl` files, and sorted record hover) |

### APIs described by declaration files

APIs implemented outside Teal (C modules, host applications that embed Lua) need no special
server support. The required pieces are:

1. `.d.tl` declaration files describing the API (records, enums, and records with methods).
2. A path the compiler can resolve, either `include_dir` in `tlconfig.lua` or
   `global_env_def` for APIs injected as globals.

Completion, hover, signature help and type checking then run through the same compiler
paths as ordinary Teal modules. M1 makes completion work while typing; M6 makes edits to
`.d.tl` files take effect without a save. `tests/workspace_test.lua` covers member completion,
signature help with parameter names, enum type errors and go-to-definition into a `.d.tl`
(using the sample module in `tests/helpers/declarations.lua`).

## Testing strategy

* Integration tests: the existing `tested` + stdio `LspClient` harness. Each milestone adds a test file.
* Rule tests (M2): `tests/rules_test.lua` runs rules in-process through `analysis.diagnostics.rule_tester`,
  without the LSP round-trip (valid/invalid/fix-output cases, as in ESLint's RuleTester).
* Regression tests for M1 bugs are written to fail on the baseline: the Invoked trigger, UTF-16 columns and MethodNotFound.
