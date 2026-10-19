local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local string = _tl_compat and _tl_compat.string or string





local tl = require("tl")
local engine = require("teal_language_server.analysis.diagnostics.engine")
local problem = require("teal_language_server.analysis.diagnostics.problem")
local rule_registry = require("teal_language_server.analysis.diagnostics.rule_registry")

local linter = {}


function linter.lint_text(code, filename, settings, env_options)
   local is_lua = filename:sub(-4) == ".lua"
   local tokens, lex_errors = tl.lex(code, filename)
   local input = {
      filename = filename,
      content = code,
      is_lua = is_lua,
      tokens = tokens,
      lex_errors = lex_errors or {},
      settings = settings,
   }
   if #input.lex_errors == 0 then
      local parse_errors = {}
      local ast = tl.parse_program(tokens, parse_errors, filename)
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
