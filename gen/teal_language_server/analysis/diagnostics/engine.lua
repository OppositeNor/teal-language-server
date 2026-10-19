local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table












local tl = require("tl")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local directives = require("teal_language_server.analysis.diagnostics.directives")
local problem = require("teal_language_server.analysis.diagnostics.problem")
local rule = require("teal_language_server.analysis.diagnostics.rule")
local rule_registry = require("teal_language_server.analysis.diagnostics.rule_registry")
local compiler_fixes = require("teal_language_server.analysis.diagnostics.compiler_fixes")
local logging = require("teal_language_server.logging")

local logger = logging.get_logger("analysis.diagnostics.engine")



local engine = { Input = {} }















local function error_range(tokens, err)
   local y = err.y or 1
   local x = err.x or 1
   local tk = tl.get_token_at(tokens, y, x)
   if tk and not tk:find("\n", 1, true) and #tk > 0 then
      return y, x, y, x + #tk
   end
   return y, x, y, x + 1
end

local function add_compiler_problems(input, out, errs, rule_id_for, severity_for)
   for _, err in ipairs(errs or {}) do
      if err.filename == nil or err.filename == input.filename then
         local severity = severity_for(err)
         if severity then
            local y, x, yend, xend = error_range(input.tokens, err)
            local p = {
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

local function type_at(input, y, x)
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

local function run_rules(input, out)
   local ast = input.ast
   local type_checked = input.result ~= nil and input.report ~= nil





   local listeners = {}
   local failed = {}

   for _, r in ipairs(rule_registry.rules) do
      local setting = input.settings.rules[r.meta.id]
      if setting and (type_checked or not r.meta.requires_types) then
         local ctx = {
            rule_id = r.meta.id,
            filename = input.filename,
            is_lua = input.is_lua,
            options = setting.options,
            tokens = input.tokens,
            ast = ast,
            report = function(_self, rep)
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
            type_at = function(_self, y, x)
               return type_at(input, y, x)
            end,
            node_start = function(_self, node)
               return ast_walk.node_start(node)
            end,
            node_end = function(_self, node, limit_y, limit_x)
               return ast_walk.node_end(input.tokens, node, limit_y, limit_x)
            end,
         }
         local ok, result = pcall(r.create, ctx)
         if ok then
            for kind, fn in pairs(result) do
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



   local combined = {}
   for kind, entries in pairs(listeners) do
      combined[kind] = function(node, parent)
         for _, entry in ipairs(entries) do
            if not failed[entry.rule_id] then
               local ok, err = pcall(entry.fn, node, parent)
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



local function directive_tokens(input)
   if input.content and input.content:sub(-1) ~= "\n" then
      local toks = tl.lex(input.content .. "\n", input.filename)
      return toks
   end
   return input.tokens
end

function engine.run(input)
   local out = {}
   local settings = input.settings

   local function syntax_id(_) return "tl/syntax-error" end
   local function always_error(_) return "error" end

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
         function(_) return "tl/type-error" end, always_error)
         add_compiler_problems(input, out, input.result.warnings,
         function(e) return "tl/" .. tostring(e.tag) end,
         function(e)

            if input.is_lua and e.msg:find("unknown variable", 1, true) then
               return nil
            end
            return settings.tl_warnings[e.tag]
         end)
         local ok, err = pcall(compiler_fixes.attach, input.content, input.tokens, input.ast, out)
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
