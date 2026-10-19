-- Lints source text held in memory, with a fresh compiler environment.
--
-- Used where the text being analyzed is not (yet) the editor buffer: fix-all
-- re-lint passes and the rule tester. A fresh env keeps these runs from
-- overwriting the shared env's type report for open documents.

local tl <const> = require("tl")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local engine <const> = require("teal_language_server.analysis.diagnostics.engine")
local problem <const> = require("teal_language_server.analysis.diagnostics.problem")
local rule_registry <const> = require("teal_language_server.analysis.diagnostics.rule_registry")

local record linter
end

function linter.lint_text(code: string, filename: string, settings: rule_registry.Settings, env_options?: tl.EnvOptions): {problem.Problem}
   local is_lua = filename:sub(-4) == ".lua"
   local tokens, lex_errors = tl.lex(code, filename)
   local input: engine.Input = {
      filename = filename,
      content = code,
      is_lua = is_lua,
      tokens = tokens,
      lex_errors = lex_errors or {},
      settings = settings,
   }
   if #input.lex_errors == 0 then
      local parse_errors: {tl.Error} = {}
      local ast = ast_walk.parse_program(tokens, parse_errors, filename)
      input.ast = ast
      input.parse_errors = parse_errors
      if #parse_errors == 0 then
         local env = tl.new_env(env_options or { defaults = {} })
         if env then
            env.report_types = true
            input.result = tl.check(ast, filename, { feat_lax = is_lua and "on" or "off", feat_arity = "on" }, env)
            input.report = env.reporter:get_report()
         end
      end
   end
   return engine.run(input)
end

return linter
