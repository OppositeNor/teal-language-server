local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local table = _tl_compat and _tl_compat.table or table




local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local rule = require("teal_language_server.analysis.diagnostics.rule")
local problem = require("teal_language_server.analysis.diagnostics.problem")










local function constant_key(op)
   local key = op.e2
   if key == nil then
      return nil
   end
   if op.op.op == "." then
      return "s:" .. key.tk
   end
   local c = key
   if key.kind == "string" and c.conststr then
      return "s:" .. c.conststr
   elseif (key.kind == "integer" or key.kind == "number") and c.constnum then
      return "n:" .. tostring(c.constnum)
   end
   return nil
end

local function same_reference(a, b)
   if a == nil or b == nil then
      return false
   end
   if a.kind == "variable" and b.kind == "variable" then
      return a.tk == b.tk
   end
   if a.kind == "op" and b.kind == "op" and a.op and b.op then
      local aop, bop = a.op.op, b.op.op
      if (aop == "." or aop == "@index") and (bop == "." or bop == "@index") then
         local ka = constant_key(a)
         return ka ~= nil and ka == constant_key(b) and same_reference(a.e1, b.e1)
      end
   end
   return false
end

local self_assignment = {
   meta = {
      id = "self-assignment",
      description = "Disallow assigning a variable or field to itself",
      type = "problem",
      has_suggestions = true,
      default_severity = "warn",
      default_options = {},
   },
   create = function(ctx)
      return {
         assignment = function(node)
            local vars, exps = node.vars, node.exps
            if vars == nil or exps == nil then
               return
            end
            local all_self = #vars == #exps
            local found = {}
            for i = 1, #vars do
               if same_reference(vars[i], exps[i]) then
                  table.insert(found, i)
               else
                  all_self = false
               end
            end
            for _, i in ipairs(found) do
               local ty, tx = ctx:node_start(vars[i])
               local ey, ex = ctx:node_end(exps[i])
               local suggestions
               if all_self then
                  local by, bx = ctx:node_start(node)
                  local sy, sx = ctx:node_end(node)
                  suggestions = {
                     {
                        title = "Remove self-assignment",
                        edits = { { y = by, x = bx, yend = sy, xend = sx, text = "" } },
                     },
                  }
               end
               ctx:report({
                  y = ty,
                  x = tx,
                  yend = ey,
                  xend = ex,
                  message = "Value is assigned to itself",
                  suggestions = suggestions,
               })
            end
         end,
      }
   end,
}

return self_assignment
