local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table




local tl = require("tl")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")



local inlay_hints = { Hint = {} }








local OBVIOUS_LITERALS = {
   string = true,
   number = true,
   integer = true,
   boolean = true,
   ["nil"] = true,
}

local MAX_LABEL = 60



local function is_annotated(tokens, idx)
   local nxt = tokens[idx + 1]
   if nxt and nxt.tk == "<" then
      nxt = tokens[idx + 4]
   end
   return nxt ~= nil and nxt.tk == ":"
end



function inlay_hints.compute(tokens, ast, type_str_at, first_line, last_line)
   local out = {}
   if ast == nil then
      return out
   end
   ast_walk.walk(ast, {
      local_declaration = function(node)
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
