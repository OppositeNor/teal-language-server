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
| Dependency invalidation | Editing an open module (or saving any file) rebuilds the env (debounced). Only the documents that are changed or depend on a changed file — transitively, through modules that are not open (`env.loaded` dependencies) — are re-checked and republished. Others keep their (still correct) diagnostics and are re-checked on their next request | `EnvUpdater:dependency_closure` / `_affected_documents`; `workspace_test`, `invalidation_test` | full (globals declared by a module are env-wide; a document using one without requiring the module is only refreshed on its next request) | `Result.dependencies`, `env.loaded` | RA salsa revisions | high | low | P4 | tests (transitive refresh, no re-check of unrelated documents); benchmark |

## Diagnostics and code actions

| Feature | Current behavior | Code / tests | Status | Semantic dependency | Comparison target | User impact | Risk | Priority | Validation |
|---|---|---|---|---|---|---|---|---|---|
| Compiler diagnostics | Staged lex → parse → type; codes `tl/<kind>`; deterministic order; `Unnecessary` tags | `diagnostics/engine.tl`; `diagnostics_test` | full | tl errors | TS diagnostics | high | low | P0 | tests |
| Lint rules | `unreachable-code`, `self-assignment`, `implicit-any`; severities and options; one AST walk | `diagnostics/rules/*`; `rules_test` | full | tl AST (+ types) | ESLint rule engine | medium | low | P2 | RuleTester-style tests |
| Suppression comments | `tls-disable[-line|-next-line]` / `tls-enable`; unused-directive reports | `directives.tl`; `rules_test` | full | none | ESLint directives | medium | low | P2 | tests |
| Quick fixes | Remove unused import, prefix with `_`, annotate implicit `any`, disable for line | `compiler_fixes.tl`, `code_actions.tl`; `code_action_test` | full (for these fixes) | tl warnings + AST | TS codefixes | medium | low | P2 | tests |
| Fix all (`source.fixAll.teal`) | Non-overlapping fixes, re-linted up to 10 passes, versioned edit | `Document:compute_fix_all`; `code_action_test` | full | as above | ESLint `source-code-fixer` | medium | low | P2 | tests |
| Organize imports | — | — | missing | requires are ordinary statements with side effects; reordering is not provably safe | TS `organizeImports` | low | medium | P3 | — |
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
| `completionItem/resolve` | Advertised. Items carry a small `data`: a local's declaration line, or the owning record's identity plus the name. Resolve adds the declaration's documentation comment to the item | `_on_completion_resolve`; `hover_docs_test` | full | `semantic.doc_comment`, `references.declarations` | tsls `cacheId` + `completionEntryDetails` | medium | low | P1 | tests |
| Auto-import completion | At a scope position with a typed prefix: workspace modules not yet required, by their last name component (`util.strings` → `strings`), excluding the current file and names already visible. `additionalTextEdits` adds `local name = require("module")` after the leading requires (or after a header comment). Tier 16, below globals | `completion.auto_import_candidates` / `import_insertion_line`, `_auto_import_candidates`; `auto_import_test` | full for modules (members of modules are reached through the module: `shapes.new`) | workspace index | TS auto-imports (`AutoImportSuggestions` "16") | medium | low | P2 | tests |
| Hover | `by_pos` at the identifier or its operator, then the name chain; markdown type and signature; answers in unparsable buffers | `_on_hover`, `formatter.tl`; `hover_test`, `completion_context_test` | full (identifiers) | `by_pos` | TS `ProvideHover`, RA `hover` | high | low | P1 | tests |
| Hover docs (comments) | The contiguous block of own-line comments directly above the declaration, which is found with the definition/references classifier (also in other open or on-disk files). Trailing comments, blocks separated by a blank line and `tls-` directives are excluded | `semantic.doc_comment`, `_declaration_doc`; `hover_docs_test` | full (hover, and completion items through `completionItem/resolve`) | tl token comments + `references.declarations` | JSDoc / rustdoc | medium | low | P1 | tests incl. exclusions |
| Signature help | Lexer finds the enclosing call and the active argument; the callee is located on tokens like a receiver (speculative check for call callees); overloads listed | `_on_signature_help`; `signature_test`, `ergonomics_test`, `completion_context_test` | full | `by_pos`, `types` | TS `getArgumentIndexOrCount`, RA `callable_for_arg_list` | high | low | P1 | tests (unfinished, nested, higher-order calls) |
| Inlay hints | Inferred types of unannotated locals; configurable | `inlay_hints.tl`; `ergonomics_test` | full (for locals) | `by_pos` | TS/RA type hints | low | low | P3 | tests |
| Semantic tokens | — | — | missing | symbol kinds per identifier | RA semantic highlighting | low | medium | P3 | — |

## Navigation and refactoring

| Feature | Current behavior | Code / tests | Status | Semantic dependency | Comparison target | User impact | Risk | Priority | Validation |
|---|---|---|---|---|---|---|---|---|---|
| Go to definition | Resolved by the same classifier as references (`references.resolve_target` + `references.declarations`): locals at their declaration, fields and methods at the record-body declaration and/or `function R:m` implementation (several `Location`s), across files. The name-chain lookup remains as a fallback for globals and module tables | `handlers/definitions.tl`; `definition_test`, `definition_sample_file_test`, `navigation_agreement_test` | full for locals and record fields; globals via the fallback | `symbols_by_file`, `types`, outline | TS `ProvideDefinition`, RA `goto_definition` + `NameRefClass` | high | low | P2 | agreement test: definition ⊆ references |
| Type definition | The declared position of the expression's type | same | full | `types` | TS | medium | low | P2 | tests |
| Definition on `require("a.b")` | On the module string or the `require` name: the module file, found by tl's `search_module` (package.path from `tlconfig.lua` `source_dir`/`include_dir`, `init.tl`, open buffers first). Locations in tl's built-in declarations (`stdlib.d.tl`, not a file) are not returned | `semantic.required_module_at`, `_required_module_location`; `require_definition_test` | full | `tl.search_module` | TS module specifier → file | high (Neovim CTRL-]) | low | P2 | tests |
| Declaration / implementation | Not offered | — | n/a (Teal has no separate declarations, except `.d.tl`) | — | — | low | — | — | — |
| References | Locals by declaration identity; globals by name; fields by (record identity, name). Globals and fields are searched in open files plus workspace files that contain the name as a word; closed candidates are type checked (cached per mtime and env) and every hit is confirmed by the resolver | `analysis/references.tl`, `NavigationHandlers:_scope_for`; `references_test`, `workspace_references_test` | full within a time budget (`references_budget_ms`, default 1500; files over 256 KiB or past the budget are not searched) | scope walk + `by_pos` | TS find-all-references (name table, then semantic pass), RA `FindUsages` | high | medium | P2 | tests: closed files, same-named field of another record excluded |
| Document highlight | Same resolver, current file | same | full | same | TS | medium | low | P2 | tests |
| Rename / prepareRename | Same identity and search as references, across the workspace. Edits to open files carry their version, to closed files `version: null`. Refuses keywords, invalid names, stdlib globals, type names, untypeable constructor keys, locations outside the workspace, and any search where a candidate file could not be fully analyzed (syntax errors, failed check, budget) | `navigation.tl`; `references_test`, `workspace_references_test` | full for locals, globals and record fields; type names refused | same | TS `renameBlockedReason`, RA `Definition::rename` | high | medium | P2 | tests: edits applied to files, exclusions, refusal |
| Document symbols | Outline from the AST (records, interfaces, enums, functions, methods, locals) | `analysis/symbols.tl`; `document_symbol_test` | full | AST | TS navtree | medium | low | P2 | tests |
| Workspace symbols | Outline index of the module roots, refreshed by mtime | `workspace_index.tl`; `workspace_test` | full | AST | TS navto | medium | low | P2 | tests |
