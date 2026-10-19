# Feature Matrix

Status as of 2026-10-18, after the "semantics for unfinished code" and "context-aware completion"
milestones. Every status was checked against the running server: tests or the probes listed in
`language-intelligence-audit.md`. A registered handler alone never counts as full support.

**Status values:**

* **full**: correct for the supported scope and tested.
* **partial**: correct where it answers, but the scope is limited (stated).
* **broken**: gives wrong answers.
* **missing**: not implemented.
* **blocked**: needs tl changes.
* **n/a**: not meaningful for Teal.

**Priority:** P0 foundations, P1 IntelliSense, P2 navigation and refactoring, P3 advanced editing, P4 scale.

## Foundations and protocol

| Feature | Current behavior | Code / tests | Status | Semantic dependency | Comparison target | User impact | Risk | Priority | Validation |
|---|---|---|---|---|---|---|---|---|---|
| Document sync (open/change/save/close) | Full-text sync, versions tracked; open buffers override disk for `require` | `handlers/document_sync.tl`, `env_updater.tl`; `did_change_test`, `workspace_test` | full (full sync only) | none | tsls `LspDocuments`, RA VFS overlay | high | low | P0 | JSON-RPC tests |
| Incremental `didChange` | Not offered (`change = Full`) | `server_state.tl` capabilities | missing | none | tsls applies ranges | low (local IPC) | low | P4 | add a range-apply test if adopted |
| Position encoding | UTF-16 ⇄ byte conversion at the protocol edge; `positionEncoding` negotiation not used (UTF-16 is the LSP default) | `util/position.tl`; `protocol_test` | full (UTF-16) | none | LSP 3.17 | high | low | P0 | non-ASCII tests |
| Semantics while the buffer does not parse | The recovered AST is type checked for queries; diagnostics show syntax errors only; no stale positions; the parser works on a copy of the tokens (it inserts synthetic ones) | `Document:ensure_semantics`, `ast_walk.parse_program`; `completion_context_test` | full (as far as tl's parser recovers) | `tl.parse_program` recovery + `tl.check` | TS error-tolerant checker, RA completion marker | **critical** | medium (relies on undocumented tl tolerance; wrapped in `pcall`) | P0 | tests fail on the old build |
| Request errors, MethodNotFound, cancellation | Error responses; `$/cancelRequest` drops queued requests; running requests are not interruptible | `lsp/events_manager.tl`; `protocol_test`, `performance_test` | partial | none | RA `Cancelled` | medium | low | P4 | JSON-RPC tests |
| Configuration | `tlconfig.lua` at the root, read at initialize; `externals.teal_language_server` for server settings | `server_state.tl` | partial: no `didChangeConfiguration` or file watching of tlconfig | none | tsls `didChangeConfiguration` | medium | low | P4 | — |
| Multiple workspace roots | One root (`rootUri`) | `misc_handlers.tl` | missing | env per root | TS projects | medium | high (one global env, `chdir`) | P4 | — |
| File create/delete/rename on disk | The workspace index refreshes by mtime on query; no `didChangeWatchedFiles` | `workspace_index.tl` | partial | none | RA VFS watcher | low | low | P4 | `workspace_test` |
| Dependency invalidation | Editing an open module rebuilds the env and re-checks all open documents (debounced) | `EnvUpdater:refresh_dependents`; `workspace_test` | full (coarse) | `Result.dependencies` | RA salsa revisions | high | medium (cost grows with open documents) | P4 | `workspace_test` |

## Diagnostics and code actions

| Feature | Current behavior | Code / tests | Status | Semantic dependency | Comparison target | User impact | Risk | Priority | Validation |
|---|---|---|---|---|---|---|---|---|---|
| Compiler diagnostics | Staged lex → parse → type; codes `tl/<kind>`; deterministic order; `Unnecessary` tags | `diagnostics/engine.tl`; `diagnostics_test` | full | tl errors | TS diagnostics | high | low | P0 | tests |
| Lint rules | `unreachable-code`, `self-assignment`, `implicit-any`; severities and options; one AST walk | `diagnostics/rules/*`; `rules_test` | full | tl AST (+ types) | ESLint rule engine | medium | low | P2 | RuleTester-style tests |
| Suppression comments | `tls-disable[-line|-next-line]` / `tls-enable`; unused-directive reports | `directives.tl`; `rules_test` | full | none | ESLint directives | medium | low | P2 | tests |
| Quick fixes | Remove unused import, prefix with `_`, annotate implicit `any`, disable for line | `compiler_fixes.tl`, `code_actions.tl`; `code_action_test` | full (for these fixes) | tl warnings + AST | TS codefixes | medium | low | P2 | tests |
| Fix all (`source.fixAll.teal`) | Non-overlapping fixes, re-linted up to 10 passes, versioned edit | `Document:compute_fix_all`; `code_action_test` | full | as above | ESLint `source-code-fixer` | medium | low | P2 | tests |
| Organize / auto-import | — | — | missing | module index + exports | TS `organizeImports`, auto-import | medium | medium | P2 | — |
| Extract variable / function | — | — | missing | reliable expression ranges + scope analysis | RA assists | low | high | P3 | — |
| Formatting | — | — | blocked (no comment-preserving formatter in tl 0.24.8) | — | — | medium | — | — | — |

## IntelliSense

| Feature | Current behavior | Code / tests | Status | Semantic dependency | Comparison target | User impact | Risk | Priority | Validation |
|---|---|---|---|---|---|---|---|---|---|
| Member completion `e.` | The receiver is located on tokens; its type is read from `by_pos` (calls: callee + returns, else a speculative parenthesized check). Fields, functions, then self-methods, in that order. Works in unparsable buffers. | `analysis/completion.tl`, `semantic.tl`; `completion_test`, `completion_context_test` | full | `by_pos`, `types` | TS `getTypeScriptMemberSymbols`, RA `complete_dot` | **high** | low | P1 | inclusion + exclusion tests |
| Method completion `e:` | Only functions whose first parameter is `self` or the receiver's type; POLY overloads included; string and enum receivers get string methods | same | full (first-parameter matching falls back to the type name for unresolved nominals, audit F5) | `types` args | TS `IsValidPropertyAccess` | high | low | P1 | tests |
| Generic receivers | Instantiated record fields (`Box<string>.item:` gives string methods); generic call results via the speculative check | same | partial: a bare type variable inside a generic body (`T is R`) is still unresolved (expected-failure test) | blocked on the tl `TypeInfo` constraint | — | medium | low | P1 | `completion_test` (xfail kept) |
| Scope completion | Visible locals (innermost wins), globals, keywords; tiers locals 10 < globals 15 < keywords 17 | same | full | `symbols_by_file` | TS `SortText`, RA `CompletionRelevance` | high | low | P1 | ordering test |
| Type-position completion | `local x: `, `(a: `, `): `, `as`, `is`, record field types: visible type declarations, primitive types, global enums and interfaces; `m.` gives nested types | same | full (aliases of primitives are offered as declared names) | AST `local_type`/`global_type` | TS `symbolCanBeReferencedAtTypeLocation` | medium | low | P1 | tests |
| Record constructor fields | `{ | }` with a record type recorded at `{`: missing fields (`name = ` inserted), methods ranked last; array/map constructors fall back to scope | same | full (when tl records the record type at `{`, including declared locals and arguments) | `by_pos` at `{` | TS object-literal completion | medium | low | P1 | tests |
| Completion blockers | Nothing in comments, strings (also unterminated), numbers, new names (`local function `, `for i`, record field names) | same | full | tree-sitter hint + tokens | TS `isCompletionListBlocker` | medium | low | P1 | tests |
| `require("…")` module names | Workspace index of module roots | `_complete_require`; `workspace_test` | full | `workspace_index` | tsls path completion | medium | low | P1 | tests |
| Snippets | Parameter placeholders when supported, omitted if a `(` follows | `_completion_item`; `ergonomics_test` | full | arg names from AST/tokens | RA call snippets | medium | low | P1 | tests |
| Expected-type literal completion (enum values in strings) | Inside a quoted string: the values of the expected enum (or of every enum in a union). The expected type comes from the call parameter (overloads included, `self` skipped for `:`), the annotated declaration, the assignment target's *declared* type, the other operand of `==`/`~=`, or the record field in a constructor. The edit replaces the string content; unterminated strings work | `analysis/completion.tl` (`literal_context`, `enum_values`, `parameter_types`); `completion_context_test` | full (for these positions; `return "…"` is not covered) | `by_pos`, `types`, scope walk | TS `getContextualType` / string literal completions | medium | low | P1 | tests incl. exclusions (`any`, `string`) |
| `completionItem/resolve` | Not used; items carry their detail and docs | — | n/a at current sizes | — | tsls `cacheId` | low | low | P4 | — |
| Auto-import completion | — | — | missing | module/export index + safe edit | TS auto-imports | medium | medium | P2 | — |
| Hover | `by_pos` at the identifier or its operator, then the name chain; markdown type and signature; answers in unparsable buffers | `_on_hover`, `formatter.tl`; `hover_test`, `completion_context_test` | full (identifiers) | `by_pos` | TS `ProvideHover`, RA `hover` | high | low | P1 | tests |
| Hover docs (comments) | Not shown | — | missing | comments attached to declarations (tl tokens carry comments) | JSDoc / rustdoc | medium | low | P1 | — |
| Signature help | Lexer finds the enclosing call and the active argument; the callee is located on tokens like a receiver (speculative check for call callees); overloads listed | `_on_signature_help`; `signature_test`, `ergonomics_test`, `completion_context_test` | full | `by_pos`, `types` | TS `getArgumentIndexOrCount`, RA `callable_for_arg_list` | high | low | P1 | tests (unfinished, nested, higher-order calls) |
| Inlay hints | Inferred types of unannotated locals; configurable | `inlay_hints.tl`; `ergonomics_test` | full (for locals) | `by_pos` | TS/RA type hints | low | low | P3 | tests |
| Semantic tokens | — | — | missing | symbol kinds per identifier | RA semantic highlighting | low | medium | P3 | — |

## Navigation and refactoring

| Feature | Current behavior | Code / tests | Status | Semantic dependency | Comparison target | User impact | Risk | Priority | Validation |
|---|---|---|---|---|---|---|---|---|---|
| Go to definition | Resolved by the same classifier as references (`references.resolve_target` + `references.declarations`): locals at their declaration, fields and methods at the record-body declaration and/or `function R:m` implementation (several `Location`s), across files. The name-chain lookup remains as a fallback for globals and module tables | `handlers/definitions.tl`; `definition_test`, `definition_sample_file_test`, `navigation_agreement_test` | full for locals and record fields; globals via the fallback | `symbols_by_file`, `types`, outline | TS `ProvideDefinition`, RA `goto_definition` + `NameRefClass` | high | low | P2 | agreement test: definition ⊆ references |
| Type definition | The declared position of the expression's type | same | full | `types` | TS | medium | low | P2 | tests |
| Declaration / implementation | Not offered | — | n/a (Teal has no separate declarations, except `.d.tl`) | — | — | low | — | — | — |
| References | Locals by declaration identity; globals by name; fields by (record identity, name) across **open** files | `analysis/references.tl`; `references_test` | partial (open files only for globals and fields) | scope walk + `by_pos` | TS find-all-references, RA `FindUsages` | high | medium | P2 | tests incl. shadowing |
| Document highlight | Same resolver, current file | same | full | same | TS | medium | low | P2 | tests |
| Rename / prepareRename | Same identity; refuses keywords, invalid names, stdlib, type names, untypeable constructor keys; versioned `WorkspaceEdit` | `navigation.tl`; `references_test` | partial: open files only for globals and fields (announced via `showMessage`); type names refused | same | TS `renameBlockedReason`, RA `Definition::rename` | high | medium | P2 | tests: only the intended occurrences |
| Document symbols | Outline from the AST (records, interfaces, enums, functions, methods, locals) | `analysis/symbols.tl`; `document_symbol_test` | full | AST | TS navtree | medium | low | P2 | tests |
| Workspace symbols | Outline index of the module roots, refreshed by mtime | `workspace_index.tl`; `workspace_test` | full | AST | TS navto | medium | low | P2 | tests |
