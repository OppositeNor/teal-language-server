local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table










local tl = require("tl")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local problem = require("teal_language_server.analysis.diagnostics.problem")
local position = require("teal_language_server.util.position")



local compiler_fixes = {}


local local_decl_kinds = {
   local_declaration = true,
   local_type = true,
   local_function = true,
   local_macroexp = true,
}

local function is_require_call(exp)
   return exp ~= nil and
   exp.kind == "op" and
   exp.op ~= nil and exp.op.op == "@funcall" and
   exp.e1 ~= nil and exp.e1.kind == "variable" and exp.e1.tk == "require"
end

local function trim(s)
   return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end



local function statement_deletion(lines, tokens, stmt)
   local sy, sx = ast_walk.statement_start(tokens, stmt)
   local ey, ex = ast_walk.node_end(tokens, stmt)
   local first_line = lines[sy] or ""
   local last_line = lines[ey] or ""
   local before = first_line:sub(1, sx - 1)
   local after = last_line:sub(ex)
   if trim(before) == "" and (trim(after) == "" or trim(after) == ";") then
      if ey < #lines then
         return { y = sy, x = 1, yend = ey + 1, xend = 1, text = "" }
      elseif sy > 1 then

         return { y = sy - 1, x = #lines[sy - 1] + 1, yend = ey, xend = #last_line + 1, text = "" }
      end
      return { y = sy, x = 1, yend = ey, xend = #last_line + 1, text = "" }
   end
   return { y = sy, x = sx, yend = ey, xend = ex, text = "" }
end

function compiler_fixes.attach(content, tokens, ast, problems)
   local wanted = {}
   local any = false
   for _, p in ipairs(problems) do
      if p.rule_id == "tl/unused" then
         wanted[p.y .. ":" .. p.x] = p
         any = true
      end
   end
   if not any or ast == nil then
      return
   end

   local lines = position.split_lines(content or "")

   ast_walk.walk(ast, {
      ["*"] = function(node, parent)
         if node.y == nil or node.x == nil then
            return
         end
         local p = wanted[node.y .. ":" .. node.x]
         if p == nil then
            return
         end




         local name_node
         if node.kind == "argument" then
            name_node = node
         elseif node.kind == "local_function" then
            name_node = node.name
         elseif node.kind == "identifier" and parent and (parent.kind == "variable_list" or local_decl_kinds[parent.kind]) then
            name_node = node
         elseif local_decl_kinds[node.kind] and node.vars and #node.vars == 1 then
            name_node = node.vars[1]
         end
         if name_node == nil or name_node.tk == nil or name_node.tk:sub(1, 1) == "_" then
            return
         end
         wanted[node.y .. ":" .. node.x] = nil

         p.suggestions = p.suggestions or {}
         table.insert(p.suggestions, {
            title = "Prefix '" .. name_node.tk .. "' with an underscore",
            edits = { { y = name_node.y, x = name_node.x, yend = name_node.y, xend = name_node.x, text = "_" } },
         })
      end,
      local_declaration = function(node)

         if node.vars == nil or #node.vars ~= 1 or node.exps == nil or #node.exps ~= 1 then
            return
         end
         local var = node.vars[1]
         if var.y == nil or var.x == nil then
            return
         end
         local key = var.y .. ":" .. var.x
         local p
         for _, cand in ipairs(problems) do
            if cand.rule_id == "tl/unused" and cand.y .. ":" .. cand.x == key then
               p = cand
            end
         end
         if p == nil or not is_require_call(node.exps[1]) then
            return
         end
         p.fix = {
            title = "Remove unused import '" .. tostring(var.tk) .. "'",
            edits = { statement_deletion(lines, tokens, node) },
         }
      end,
   })
end

return compiler_fixes
