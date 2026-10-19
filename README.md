[![Test all the OS/Platforms](https://github.com/teal-language/teal-language-server/actions/workflows/platform-test.yaml/badge.svg?branch=main)](https://github.com/teal-language/teal-language-server/actions/workflows/platform-test.yaml)

# Teal Language Server

A language server for the [Teal language](https://github.com/teal-language/tl)

## Features

* Diagnostics (`textDocument/publishDiagnostics`): compiler errors and warnings plus lint rules, with rule codes, configurable severities and suppression comments (see [Configuration](#configuration))
* Completion (`textDocument/completion`), also while the current statement is unfinished: record fields and `:` methods of the receiver's type (including call results and generic instantiations), visible names ranked locals before globals before keywords, type names in type annotations, missing fields in record constructors, enum values inside strings where an enum is expected (arguments, declarations, assignments, comparisons, constructor fields), `require("...")` module names; type details, signatures and snippet placeholders when the editor supports them. Nothing is offered in comments, strings or new names
* Hover (`textDocument/hover`): type or signature, plus the documentation comment written above the declaration
* Signature help (`textDocument/signatureHelp`), with the active parameter highlighted anywhere in the call, including unfinished and nested calls
* Go to definition / type definition (`textDocument/definition`, `textDocument/typeDefinition`)
* Find references and document highlight (`textDocument/references`, `textDocument/documentHighlight`): locals, globals, and record fields and methods across open files
* Rename (`textDocument/prepareRename`, `textDocument/rename`)
* Code actions (`textDocument/codeAction`): quick fixes (remove unused import, prefix unused variable with `_`, annotate an implicit `any`, disable a rule for a line) and "Fix all" (`source.fixAll.teal`)
* Document outline (`textDocument/documentSymbol`) and workspace symbol search (`workspace/symbol`)
* Inlay hints (`textDocument/inlayHint`) showing inferred types of unannotated locals
* Unsaved edits to a module are visible to the files that `require` it

## Installation

### From GitHub Release Binaries (Windows)
We provide binaries for Windows on our [GitHub Release](https://github.com/teal-language/teal-language-server/releases) page. You should be able to download and extract the the latest version from there.

### via LuaRocks

If using LuaRocks, be sure to have LuaRocks binary path available on your PATH!

On macOS and Linux, the standard `luarocks install` should work:

- `luarocks install teal-language-server`

On Windows:
- If using Visual Studio, please be sure to have the C++ build tools, and note that the default cmake generator (`Visual Studio 14 2015`) does not work. We recommend using `NMake Makefiles`
    ```bash
    luarocks config cmake_generator "NMake Makefiles"
    luarocks install teal-language-server
    ```

- If using mingw, additional `CFLAGS` also need to be set so some of the upstream dependencies will compile:
    ```bash
    set CFLAGS=-O2 -Wno-int-conversion -Wno-incompatible-pointer-types
    luarocks config cmake_generator "MinGW Makefiles"
    luarocks install teal-language-server
    ```
    If using Powershell, set the CFLAGS with: `$env:CFLAGS = "-O2 -Wno-int-conversion -Wno-incompatible-pointer-types"`


### From source

1. Clone repo
2. Run a `luarocks make` - this should work however your LuaRocks is setup!
    - If using Windows, please set the `cmake_generator` and `CFLAGS` as described in the installation section!

## Editor Setup

### Neovim

Install the [lspconfig plugin](https://github.com/neovim/nvim-lspconfig) and put the following in your `init.vim` or `init.lua`

```lua
local lspconfig = require("lspconfig")

-- as long as teal-language-server is in your PATH this should work
lspconfig.teal_ls.setup {}

-- if it's not in your path, you can specify where teal-languag-server is by setting cmd. For example on Windows:
-- lspconfig.teal_ls.setup({cmd = { 'C:\\opt\\tls-windows\\bin\\teal-language-server.bat' },})
```

## Usage

```
teal-language-server [--verbose=true] [--log-mode=none|by_proj_path|by_date]
```

Note:

* All args are optional
* By default, logging is 'none' which disables logging completely
* When logging is set to `by_proj_path` or `by_date`, the log is output to `[User Home Directory]/.cache/teal-language-server`

## Configuration

The server reads `tlconfig.lua` from the workspace root: the same file `tl` and `cyan` use (`include_dir`, `source_dir`, `global_env_def`, `gen_target`, `disable_warnings`, `warning_error`, ...). Server-specific settings go in the `externals` table, which `tl` reserves for other tools:

```lua
return {
   include_dir = { "types" },
   externals = {
      teal_language_server = {
         rules = {
            ["unreachable-code"] = "error",                    -- "off" | "warn" | "error" (or 0 | 1 | 2)
            ["implicit-any"] = { "warn", { ignore_pattern = "^_" } },
            ["self-assignment"] = "warn",
            ["tl/unused"] = "off",                             -- compiler warning kinds, too
         },
         report_unused_directives = "warn",  -- flag suppression comments that suppress nothing
         inlay_hints = true,
         diagnostics_delay_ms = 150,         -- debounce for diagnostics after edits
      },
   },
}
```

An invalid `tlconfig.lua`, an unknown rule, or a bad severity is reported in the editor; the server keeps working with defaults.

### Lint rules

| Rule | Default | Reports |
|---|---|---|
| `unreachable-code` | warn | statements after `break`, `goto`, or a `do ... end` that returns |
| `self-assignment` | warn | `x = x`, `t.a = t["a"]` |
| `implicit-any` | warn | function parameters without a type annotation (they are `any` in Teal); options `check_lua` (default `false`) and `ignore_pattern` (default `"^_"`) |
| `tl/<kind>` | warn | the compiler's own warnings (`tl/unused`, `tl/redeclaration`, `tl/branch`, ...) |

Compiler type and syntax errors are reported as `tl/type-error` and `tl/syntax-error`.

### Suppression comments

```lua
-- tls-disable-next-line implicit-any -- signature is dictated by the caller
local function on_event(e) end
local x = 1 -- tls-disable-line tl/unused

-- tls-disable unreachable-code
...
-- tls-enable unreachable-code
```

Without a rule list, a directive applies to every rule.

### APIs implemented outside Teal

Describe APIs implemented outside Teal (C modules, host applications embedding Lua) in a `.d.tl` declaration file. Put it on `include_dir`, or use `global_env_def` for APIs injected as globals. Completion, signature help, type checking and navigation then work as they do for Teal modules.

## Development

```
luarocks make --tree=luarocks_tree   # build + install
cyan build                           # type check and regenerate gen/
tested -n 0 tests/                   # run the test suite (tested 0.3.x)
```

Latency benchmark (see `docs/engineering/performance-baseline.md`):

```
lua5.4 scripts/bench_latency.lua teal-language-server 30   # with luarocks_tree on LUA_PATH/LUA_CPATH
```

Design notes in `docs/engineering/`: `language-intelligence-audit.md`, `feature-matrix.md`,
`semantic-architecture.md`, `implementation-roadmap.md`, `performance-baseline.md`, and the earlier
`language-server-gap-analysis.md` / `language-server-roadmap.md` (diagnostics engine, M1–M8).

## Licences
Alongside packages defined in the rockspec, teal-language-server includes the source of the following:

- [tree-sitter-teal](https://github.com/euclidianAce/tree-sitter-teal) - MIT
  - Bundling directly makes install more reliable, as tree-sitter-cli does not need to be setup for the install to work
