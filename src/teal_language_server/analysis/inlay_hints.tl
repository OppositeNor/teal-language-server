-- Inlay hints: the type the compiler inferred for `local` variables that have
-- no annotation, e.g. `local tex = graph:create_texture(...)` shows
-- `: TextureHandle` after `tex`. Variables initialized with a literal of an
-- obvious type (string, number, boolean, nil) are skipped.

local tl <const> = require("tl")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")

local type AstNode = ast_walk.AstNode

local record inlay_hints
   record Hint
      -- position right after the variable name (tl coordinates)
      y: integer
      x: integer
      label: string
   end
end

local OBVIOUS_LITERALS <const>: {string:boolean} = {
   string = true,
   number = true,
   integer = true,
   boolean = true,
   ["nil"] = true,
}

local MAX_LABEL <const> = 60

-- Whether the variable token at `idx` is followed by a type annotation,
-- possibly after an attribute: `x: T`, `x <const>: T`.
local function is_annotated(tokens: {tl.Token}, idx: integer): boolean
   local nxt = tokens[idx + 1]
   if nxt and nxt.tk == "<" then
      nxt = tokens[idx + 4]
   end
   return nxt ~= nil and nxt.tk == ":"
end

-- `type_str_at(y, x)` returns the display string of the type tl recorded at a
-- position (or nil). Hints are produced for lines first_line..last_line.
function inlay_hints.compute(tokens: {tl.Token}, ast: AstNode, type_str_at: function(integer, integer): string, first_line: integer, last_line: integer): {inlay_hints.Hint}
   local out: {inlay_hints.Hint} = {}
   if ast == nil then
      return out
   end
   ast_walk.walk(ast, {
      local_declaration = function(node: AstNode)
         if node.vars == nil or node.y < first_line or node.y > last_line then
            return
         end
         for i, var in ipairs(node.vars) do
            local exp = node.exps and node.exps[i]
            if var.tk and var.y and not (exp and OBVIOUS_LITERALS[exp.kind]) then
               local idx = ast_walk.token_index_at(tokens, var.y, var.x)
               local tok = tokens[idx]
               if tok and tok.y == var.y and tok.x == var.x and not is_annotated(tokens, idx) then
                  local str = type_str_at(var.y, var.x)
                  if str and str ~= "" and not str:match("^<") then
                     -- drop tl's "(inferred at file:y:x)" suffix
                     str = str:gsub("%s*%(inferred at [^)]*%)$", "")
                     if #str > MAX_LABEL then
                        str = str:sub(1, MAX_LABEL - 3) .. "..."
                     end
                     table.insert(out, { y = var.y, x = var.x + #var.tk, label = ": " .. str })
                  end
               end
            end
         end
      end,
   })
   return out
end

return inlay_hints
