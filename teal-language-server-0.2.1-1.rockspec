rockspec_format = "3.0"

package = "teal-language-server"
version = "0.2.1-1"

source = {
   url = "git+https://github.com/teal-language/teal-language-server.git",
   tag = "0.2.1"
}

description = {
   summary = "A language server for the Teal language",
   detailed = "A language server for the Teal language",
   homepage = "https://github.com/teal-language/teal-language-server",
   license = "MIT"
}

dependencies = {
   "luafilesystem",
   "tl == 0.24.8",
   "lua-cjson",
   "argparse",
   "luv == 1.52.1",
   "lusc_luv >= 4.0",
   "ltreesitter == 0.3.0",
}

test_dependencies = { "tested >= 0.3.0, < 0.4.0", "luacov", "inspect" }

test = {
   type = "tested",
}

build = {
   type = "builtin",
   modules = {
      -- tree-sitter-teal (removes need for tree-sitter-cli and a build dep)
      ["teal"] = {"tree-sitter-teal/src/parser.c", "tree-sitter-teal/src/scanner.c", "tree-sitter-teal/src/lua_stub.c", incdirs = {"tree-sitter-teal/src"},},

      -- core
      ["teal_language_server.args_parser"] = "gen/teal_language_server/args_parser.lua",
      ["teal_language_server.main"] = "gen/teal_language_server/main.lua",
      ["teal_language_server.server_state"] = "gen/teal_language_server/server_state.lua",
      ["teal_language_server.logging"] = "gen/teal_language_server/logging.lua",
      ["teal_language_server.log_file"] = "gen/teal_language_server/log_file.lua",

      -- teal analysis
      ["teal_language_server.analysis.document"] = "gen/teal_language_server/analysis/document.lua",
      ["teal_language_server.analysis.document_manager"] = "gen/teal_language_server/analysis/document_manager.lua",
      ["teal_language_server.analysis.env_updater"] = "gen/teal_language_server/analysis/env_updater.lua",
      ["teal_language_server.analysis.lua_env"] = "gen/teal_language_server/analysis/lua_env.lua",

      ["teal_language_server.analysis.symbols"] = "gen/teal_language_server/analysis/symbols.lua",
      ["teal_language_server.analysis.references"] = "gen/teal_language_server/analysis/references.lua",
      ["teal_language_server.analysis.inlay_hints"] = "gen/teal_language_server/analysis/inlay_hints.lua",
      ["teal_language_server.analysis.semantic"] = "gen/teal_language_server/analysis/semantic.lua",
      ["teal_language_server.analysis.completion"] = "gen/teal_language_server/analysis/completion.lua",
      ["teal_language_server.analysis.workspace_index"] = "gen/teal_language_server/analysis/workspace_index.lua",

      -- diagnostics engine and lint rules
      ["teal_language_server.analysis.diagnostics.problem"] = "gen/teal_language_server/analysis/diagnostics/problem.lua",
      ["teal_language_server.analysis.diagnostics.ast_walk"] = "gen/teal_language_server/analysis/diagnostics/ast_walk.lua",
      ["teal_language_server.analysis.diagnostics.rule"] = "gen/teal_language_server/analysis/diagnostics/rule.lua",
      ["teal_language_server.analysis.diagnostics.rule_registry"] = "gen/teal_language_server/analysis/diagnostics/rule_registry.lua",
      ["teal_language_server.analysis.diagnostics.directives"] = "gen/teal_language_server/analysis/diagnostics/directives.lua",
      ["teal_language_server.analysis.diagnostics.fixer"] = "gen/teal_language_server/analysis/diagnostics/fixer.lua",
      ["teal_language_server.analysis.diagnostics.engine"] = "gen/teal_language_server/analysis/diagnostics/engine.lua",
      ["teal_language_server.analysis.diagnostics.linter"] = "gen/teal_language_server/analysis/diagnostics/linter.lua",
      ["teal_language_server.analysis.diagnostics.compiler_fixes"] = "gen/teal_language_server/analysis/diagnostics/compiler_fixes.lua",
      ["teal_language_server.analysis.diagnostics.rule_tester"] = "gen/teal_language_server/analysis/diagnostics/rule_tester.lua",
      ["teal_language_server.analysis.diagnostics.rules.unreachable_code"] = "gen/teal_language_server/analysis/diagnostics/rules/unreachable_code.lua",
      ["teal_language_server.analysis.diagnostics.rules.self_assignment"] = "gen/teal_language_server/analysis/diagnostics/rules/self_assignment.lua",
      ["teal_language_server.analysis.diagnostics.rules.implicit_any"] = "gen/teal_language_server/analysis/diagnostics/rules/implicit_any.lua",

      -- handler
      ["teal_language_server.handlers.navigation"] = "gen/teal_language_server/handlers/navigation.lua",
      ["teal_language_server.handlers.code_actions"] = "gen/teal_language_server/handlers/code_actions.lua",
      ["teal_language_server.handlers.definitions"] = "gen/teal_language_server/handlers/definitions.lua",
      ["teal_language_server.handlers.handler_helper"] = "gen/teal_language_server/handlers/handler_helper.lua",
      ["teal_language_server.handlers.document_sync"] = "gen/teal_language_server/handlers/document_sync.lua",
      ["teal_language_server.handlers.language_features"] = "gen/teal_language_server/handlers/language_features.lua",
      ["teal_language_server.handlers.misc_handlers"] = "gen/teal_language_server/handlers/misc_handlers.lua",

      -- lsp protocol
      ["teal_language_server.lsp.events_manager"] = "gen/teal_language_server/lsp/events_manager.lua",
      ["teal_language_server.lsp.formatter"] = "gen/teal_language_server/lsp/formatter.lua",
      ["teal_language_server.lsp.protocol"] = "gen/teal_language_server/lsp/protocol.lua",
      ["teal_language_server.lsp.reader_writer"] = "gen/teal_language_server/lsp/reader_writer.lua",
      ["teal_language_server.lsp.stdin_reader"] = "gen/teal_language_server/lsp/stdin_reader.lua",

      -- util
      ["teal_language_server.util.asserts"] = "gen/teal_language_server/util/asserts.lua",
      ["teal_language_server.util.class"] = "gen/teal_language_server/util/class.lua",
      ["teal_language_server.util.path"] = "gen/teal_language_server/util/path.lua",
      ["teal_language_server.util.uri"] = "gen/teal_language_server/util/uri.lua",
      ["teal_language_server.util.position"] = "gen/teal_language_server/util/position.lua",
      ["teal_language_server.util.util"] = "gen/teal_language_server/util/util.lua",
   },
   install = {
     bin = {
       ['teal-language-server'] = 'bin/teal-language-server'
     }
   }
}
