-- Reports assignments of a variable or field to itself (`x = x`,
-- `t.a = t["a"]`). These are almost always a typo for a different target or
-- source. No automatic fix is offered: a field self-assignment can have side
-- effects through __index/__newindex metamethods, so removal is a suggestion.

local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local rule <const> = require("teal_language_server.analysis.diagnostics.rule")
local problem <const> = require("teal_language_server.analysis.diagnostics.problem")

local type AstNode = ast_walk.AstNode

local record ConstNode
   conststr: string
   constnum: number
end

-- The key accessed by a `.` or `@index` op, as a comparable string, or nil if
-- the key is not a constant.
local function constant_key(op: AstNode): string
   local key = op.e2
   if key == nil then
      return nil
   end
   if op.op.op == "." then
      return "s:" .. key.tk
   end
   local c = key as any as ConstNode
   if key.kind == "string" and c.conststr then
      return "s:" .. c.conststr
   elseif (key.kind == "integer" or key.kind == "number") and c.constnum then
      return "n:" .. tostring(c.constnum)
   end
   return nil
end

local function same_reference(a: AstNode, b: AstNode): boolean
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

local self_assignment: rule.Rule = {
   meta = {
      id = "self-assignment",
      description = "Disallow assigning a variable or field to itself",
      type = "problem",
      has_suggestions = true,
      default_severity = "warn",
      default_options = {},
   },
   create = function(ctx: rule.Context): {string:ast_walk.Listener}
      return {
         assignment = function(node: AstNode)
            local vars, exps = node.vars, node.exps
            if vars == nil or exps == nil then
               return
            end
            local all_self = #vars == #exps
            local found: {integer} = {}
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
               local suggestions: {problem.Fix}
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
