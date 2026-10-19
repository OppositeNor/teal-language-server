local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local table = _tl_compat and _tl_compat.table or table









local tl = require("tl")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")



local symbols = { Symbol = {} }




























symbols.kind_to_lsp = {
   Module = 2,
   Class = 5,
   Method = 6,
   Field = 8,
   Enum = 10,
   Interface = 11,
   Function = 12,
   Variable = 13,
   Constant = 14,
   EnumMember = 22,
   TypeParameter = 26,
}












local function def_kind(def)
   if def == nil then
      return "TypeParameter"
   end
   if def.typename == "record" then
      return "Class"
   elseif def.typename == "interface" then
      return "Interface"
   elseif def.typename == "enum" then
      return "Enum"
   end
   return "TypeParameter"
end

local function sel(s, y, x, name)
   s.sel_y, s.sel_x, s.sel_yend, s.sel_xend = y, x, y, x + #name
end




local function find_name_token(tokens, y, x, name)
   local idx = ast_walk.token_index_at(tokens, y, x)
   for d = 0, 4 do
      for _, i in ipairs({ idx - d, idx + d }) do
         local t = tokens[i]
         if t and t.tk == name and t.kind == "identifier" then
            return t
         end
      end
   end
   return nil
end

local function type_members(tokens, def, parent)
   local out = {}
   if def == nil then
      return out
   end
   if def.typename == "enum" and def.enumset then
      local names = {}
      for k in pairs(def.enumset) do
         table.insert(names, k)
      end
      table.sort(names)
      for _, k in ipairs(names) do

         table.insert(out, {
            name = k,
            kind = "EnumMember",
            y = parent.sel_y, x = parent.sel_x, yend = parent.sel_yend, xend = parent.sel_xend,
            sel_y = parent.sel_y, sel_x = parent.sel_x, sel_yend = parent.sel_yend, sel_xend = parent.sel_xend,
         })
      end
      return out
   end
   if not def.field_order then
      return out
   end
   for _, name in ipairs(def.field_order) do
      local ft = def.fields[name]
      if ft and ft.y then
         local s = { name = name }
         local tok = find_name_token(tokens, ft.y, ft.x, name)
         if tok then
            sel(s, tok.y, tok.x, name)
         else
            sel(s, ft.y, ft.x, name)
         end
         if ft.typename == "typedecl" then
            s.kind = def_kind(ft.def)
            s.detail = ft.def and ft.def.typename
         elseif ft.typename == "function" or ft.typename == "poly" then
            s.kind = "Method"
         else
            s.kind = "Field"
         end

         if ft.y < s.sel_y or (ft.y == s.sel_y and ft.x < s.sel_x) then
            s.y, s.x = ft.y, ft.x
         else
            s.y, s.x = s.sel_y, s.sel_x
         end
         table.insert(out, s)
      end
   end


   for i, s in ipairs(out) do
      local nxt = out[i + 1]
      if nxt then
         local ny, nx = nxt.y, nxt.x

         local idx = ast_walk.token_index_at(tokens, ny, nx) - 1
         local prev = tokens[idx]
         if prev and (prev.y > s.sel_y or (prev.y == s.sel_y and prev.x >= s.sel_x)) then
            s.yend, s.xend = ast_walk.token_end(prev)
         else
            s.yend, s.xend = s.sel_yend, s.sel_xend
         end
      else

         local idx = ast_walk.token_index_at(tokens, parent.yend, parent.xend - 1)
         local prev = tokens[idx - 1]
         if prev and (prev.y > s.sel_y or (prev.y == s.sel_y and prev.x >= s.sel_x)) then
            s.yend, s.xend = ast_walk.token_end(prev)
         else
            s.yend, s.xend = s.sel_yend, s.sel_xend
         end
      end
      if s.kind == "Class" or s.kind == "Interface" or s.kind == "Enum" then
         local fdef = def.fields[s.name].def
         s.children = type_members(tokens, fdef, s)
      end
   end
   return out
end


local function owner_name(fn_owner)
   if fn_owner == nil then
      return nil
   end
   if fn_owner.tk then
      return fn_owner.tk
   end
   if fn_owner.kind == "op" and fn_owner.e1 then
      return owner_name(fn_owner.e1)
   end
   return nil
end

local function statement_symbol(tokens, stmt, name_node, kind)
   local y, x = ast_walk.statement_start(tokens, stmt)
   local yend, xend = ast_walk.node_end(tokens, stmt)
   local s = { name = name_node.tk, kind = kind, y = y, x = x, yend = yend, xend = xend }
   sel(s, name_node.y, name_node.x, name_node.tk)
   return s
end


function symbols.document_symbols(tokens, ast)
   local out = {}
   local by_name = {}
   if ast == nil then
      return out
   end

   for _, stmt in ipairs(ast) do
      local kind = stmt.kind
      if (kind == "local_type" or kind == "global_type") and stmt.var and stmt.var.tk then
         local nt = stmt.value and stmt.value.newtype
         local def = nt and nt.def
         local s = statement_symbol(tokens, stmt, stmt.var, def_kind(def))
         s.detail = def and def.typename
         s.children = type_members(tokens, def, s)
         table.insert(out, s)
         by_name[s.name] = s
      elseif (kind == "local_function" or kind == "global_function") and stmt.name and stmt.name.tk then
         local s = statement_symbol(tokens, stmt, stmt.name, "Function")
         table.insert(out, s)
         by_name[s.name] = s
      elseif kind == "record_function" and stmt.name and stmt.name.tk then
         local owner = owner_name(stmt.fn_owner)
         local parent = owner and by_name[owner]
         local s = statement_symbol(tokens, stmt, stmt.name, stmt.is_method and "Method" or "Function")
         if parent then

            parent.children = parent.children or {}
            local replaced = false
            for i, c in ipairs(parent.children) do
               if c.name == s.name and (c.kind == "Method" or c.kind == "Field") then
                  s.declaration = c
                  parent.children[i] = s
                  replaced = true
                  break
               end
            end
            if not replaced then
               table.insert(parent.children, s)
            end

            if s.yend > parent.yend or (s.yend == parent.yend and s.xend > parent.xend) then
               parent.yend, parent.xend = s.yend, s.xend
            end
         else
            s.name = (owner and (owner .. (stmt.is_method and ":" or ".")) or "") .. s.name
            table.insert(out, s)
         end
      elseif (kind == "local_declaration" or kind == "global_declaration") and stmt.vars then
         for _, var in ipairs(stmt.vars) do
            if var.tk and var.y then
               local s = statement_symbol(tokens, stmt, var, var.attribute == "const" and "Constant" or "Variable")
               table.insert(out, s)
               by_name[s.name] = s
            end
         end
      end
   end

   return out
end


function symbols.flatten(list, container, out)
   out = out or {}
   for _, s in ipairs(list) do
      table.insert(out, { s, container })
      if s.children then
         symbols.flatten(s.children, s.name, out)
      end
   end
   return out
end

return symbols
