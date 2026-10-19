-- The diagnostics engine: turns one analyzed document into an ordered list of
-- problems.
--
--   1. compiler problems: lex errors, else parse errors, else type errors and
--      warnings (labeled "tl/<kind>"; severity from tlconfig / rule settings)
--   2. lint rules (only on a successful parse; type-aware rules only when the
--      type checker ran), all rules sharing a single AST traversal
--   3. suppression directives
--   4. deterministic ordering
--
-- The engine works on plain inputs (no Document / LSP types) so it can be used
-- by the rule tester and by fix-all re-runs on in-memory text.

local tl <const> = require("tl")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local directives <const> = require("teal_language_server.analysis.diagnostics.directives")
local problem <const> = require("teal_language_server.analysis.diagnostics.problem")
local rule <const> = require("teal_language_server.analysis.diagnostics.rule")
local rule_registry <const> = require("teal_language_server.analysis.diagnostics.rule_registry")
local compiler_fixes <const> = require("teal_language_server.analysis.diagnostics.compiler_fixes")
local logging <const> = require("teal_language_server.logging")

local logger = logging.get_logger("analysis.diagnostics.engine")

local type AstNode = ast_walk.AstNode

local record engine
   record Input
      filename: string
      content: string
      is_lua: boolean
      tokens: {tl.Token}
      lex_errors: {tl.Error}
      ast: tl.Node
      parse_errors: {tl.Error}
      -- nil when type checking did not run
      result: tl.Result
      report: tl.TypeReport
      settings: rule_registry.Settings
   end
end

local function error_range(tokens: {tl.Token}, err: tl.Error): integer, integer, integer, integer
   local y = err.y or 1
   local x = err.x or 1
   local tk = tl.get_token_at(tokens, y, x)
   if tk and not tk:find("\n", 1, true) and #tk > 0 then
      return y, x, y, x + #tk
   end
   return y, x, y, x + 1
end

local function add_compiler_problems(input: engine.Input, out: {problem.Problem}, errs: {tl.Error}, rule_id_for: function(tl.Error): string, severity_for: function(tl.Error): problem.Severity)
   for _, err in ipairs(errs or {}) do
      if err.filename == nil or err.filename == input.filename then
         local severity = severity_for(err)
         if severity then
            local y, x, yend, xend = error_range(input.tokens, err)
            local p: problem.Problem = {
               rule_id = rule_id_for(err),
               severity = severity,
               message = err.msg,
               y = y,
               x = x,
               yend = yend,
               xend = xend,
            }
            if err.tag == "unused" then
               p.tags = { "unnecessary" }
            end
            table.insert(out, p)
         end
      end
   end
end

local function type_at(input: engine.Input, y: integer, x: integer): tl.TypeInfo
   local tr = input.report
   if tr == nil then return nil end
   local file = tr.by_pos[input.filename]
   local row = file and file[y]
   local id = row and row[x]
   local ti = id and tr.types[id]
   local guard = 0
   while ti and ti.ref and guard < 100 do
      ti = tr.types[ti.ref]
      guard = guard + 1
   end
   return ti
end

local function run_rules(input: engine.Input, out: {problem.Problem})
   local ast = input.ast as AstNode
   local type_checked = input.result ~= nil and input.report ~= nil

   local record Entry
      rule_id: string
      fn: ast_walk.Listener
   end
   local listeners: {string:{Entry}} = {}
   local failed: {string:boolean} = {}

   for _, r in ipairs(rule_registry.rules) do
      local setting = input.settings.rules[r.meta.id]
      if setting and (type_checked or not r.meta.requires_types) then
         local ctx: rule.Context = {
            rule_id = r.meta.id,
            filename = input.filename,
            is_lua = input.is_lua,
            options = setting.options,
            tokens = input.tokens,
            ast = ast,
            report = function(_self: rule.Context, rep: rule.Report)
               local y, x, yend, xend = rep.y, rep.x, rep.yend, rep.xend
               if rep.node then
                  y, x = ast_walk.node_start(rep.node)
                  yend, xend = ast_walk.node_end(input.tokens, rep.node)
               end
               table.insert(out, {
                  rule_id = r.meta.id,
                  severity = setting.severity,
                  message = rep.message,
                  y = y,
                  x = x,
                  yend = yend or y,
                  xend = xend or (x + 1),
                  tags = rep.tags,
                  fix = r.meta.fixable and rep.fix or nil,
                  suggestions = r.meta.has_suggestions and rep.suggestions or nil,
               })
            end,
            type_at = function(_self: rule.Context, y: integer, x: integer): tl.TypeInfo
               return type_at(input, y, x)
            end,
            node_start = function(_self: rule.Context, node: AstNode): integer, integer
               return ast_walk.node_start(node)
            end,
            node_end = function(_self: rule.Context, node: AstNode, limit_y?: integer, limit_x?: integer): integer, integer
               return ast_walk.node_end(input.tokens, node, limit_y, limit_x)
            end,
         }
         local ok, result = pcall(r.create, ctx)
         if ok then
            for kind, fn in pairs(result as {string:ast_walk.Listener}) do
               listeners[kind] = listeners[kind] or {}
               table.insert(listeners[kind], { rule_id = r.meta.id, fn = fn })
            end
         else
            logger:error("Rule %s failed to initialize: %s", r.meta.id, tostring(result))
         end
      end
   end

   if next(listeners) == nil then
      return
   end

   -- one traversal for all rules; a rule that raises is disabled for the rest
   -- of this run so that one buggy rule cannot take down all diagnostics
   local combined: {string:ast_walk.Listener} = {}
   for kind, entries in pairs(listeners) do
      combined[kind] = function(node: AstNode, parent: AstNode)
         for _, entry in ipairs(entries) do
            if not failed[entry.rule_id] then
               local ok, err = pcall(entry.fn, node, parent) as (boolean, any)
               if not ok then
                  failed[entry.rule_id] = true
                  logger:error("Rule %s raised on %s:%s:%s: %s", entry.rule_id, input.filename, tostring(node.y), tostring(node.x), tostring(err))
               end
            end
         end
      end
   end
   ast_walk.walk(ast, combined)
end

-- Tokens used for directive parsing. tl's lexer drops a comment on the last
-- line when the text has no trailing newline, so lex a terminated copy then.
local function directive_tokens(input: engine.Input): {tl.Token}
   if input.content and input.content:sub(-1) ~= "\n" then
      local toks = tl.lex(input.content .. "\n", input.filename)
      return toks
   end
   return input.tokens
end

function engine.run(input: engine.Input): {problem.Problem}
   local out: {problem.Problem} = {}
   local settings = input.settings

   local function syntax_id(_: tl.Error): string return "tl/syntax-error" end
   local function always_error(_: tl.Error): problem.Severity return "error" end

   if input.lex_errors and #input.lex_errors > 0 then
      for _, err in ipairs(input.lex_errors) do
         err.msg = err.msg or "invalid token"
      end
      add_compiler_problems(input, out, input.lex_errors, syntax_id, always_error)
   elseif input.parse_errors and #input.parse_errors > 0 then
      add_compiler_problems(input, out, input.parse_errors, syntax_id, always_error)
   else
      if input.result then
         add_compiler_problems(input, out, input.result.type_errors,
            function(_: tl.Error): string return "tl/type-error" end, always_error)
         add_compiler_problems(input, out, input.result.warnings,
            function(e: tl.Error): string return "tl/" .. tostring(e.tag) end,
            function(e: tl.Error): problem.Severity
               -- lax .lua files reference unknown globals all the time
               if input.is_lua and e.msg:find("unknown variable", 1, true) then
                  return nil
               end
               return settings.tl_warnings[e.tag]
            end)
         local ok, err = pcall(compiler_fixes.attach, input.content, input.tokens, input.ast as AstNode, out) as (boolean, any)
         if not ok then
            logger:error("Computing compiler fixes failed for %s: %s", input.filename, tostring(err))
         end
      end
      run_rules(input, out)
   end

   out = directives.apply(out, directives.parse(directive_tokens(input)), settings.unused_directives)
   problem.sort(out)
   return out
end

return engine
