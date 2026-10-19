-- Document symbols (outline) from the tl AST.
--
-- Uses the parse tree only, so it works on files with type errors and, as far
-- as tl's error-recovering parser gets, on files with syntax errors. Record,
-- interface and enum members come from the declared type attached to the
-- `newtype` node (`def.field_order` / `def.fields` / `def.enumset`).
--
-- Positions are tl coordinates (1-based line and byte column, end exclusive);
-- the handler converts them to LSP.

local tl <const> = require("tl")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")

local type AstNode = ast_walk.AstNode

local record symbols
   -- LSP SymbolKind values
   enum Kind
      "Class" "Interface" "Enum" "EnumMember" "TypeParameter"
      "Function" "Method" "Field" "Variable" "Constant" "Module"
   end
   kind_to_lsp: {Kind:integer}

   record Symbol
      name: string
      kind: Kind
      detail: string
      -- full extent
      y: integer
      x: integer
      yend: integer
      xend: integer
      -- the name
      sel_y: integer
      sel_x: integer
      sel_yend: integer
      sel_xend: integer
      children: {Symbol}
      -- for a method implementation that replaced the record's declaration of
      -- the same field in the outline: that declaration
      declaration: Symbol
   end
end

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

-- the parts of tl's (internal) Type objects used here
local record TypeObj
   typename: string
   y: integer
   x: integer
   def: TypeObj
   field_order: {string}
   fields: {string:TypeObj}
   enumset: {string:boolean}
end

local function def_kind(def: TypeObj): symbols.Kind
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

local function sel(s: symbols.Symbol, y: integer, x: integer, name: string)
   s.sel_y, s.sel_x, s.sel_yend, s.sel_xend = y, x, y, x + #name
end

-- Finds the token naming `name` near the token at (y, x): fields and nested
-- types are positioned at their type annotation or at their keyword, not at
-- the name itself.
local function find_name_token(tokens: {tl.Token}, y: integer, x: integer, name: string): tl.Token
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

local function type_members(tokens: {tl.Token}, def: TypeObj, parent: symbols.Symbol): {symbols.Symbol}
   local out: {symbols.Symbol} = {}
   if def == nil then
      return out
   end
   if def.typename == "enum" and def.enumset then
      local names: {string} = {}
      for k in pairs(def.enumset) do
         table.insert(names, k)
      end
      table.sort(names)
      for _, k in ipairs(names) do
         -- tl does not keep enum value positions; point at the enum itself
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
         local s: symbols.Symbol = { name = name }
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
         -- start at whichever comes first: the name or the keyword/annotation
         if ft.y < s.sel_y or (ft.y == s.sel_y and ft.x < s.sel_x) then
            s.y, s.x = ft.y, ft.x
         else
            s.y, s.x = s.sel_y, s.sel_x
         end
         table.insert(out, s)
      end
   end
   -- each member extends to the next member (or the end of the parent), which
   -- keeps children nested inside their parent's range as LSP requires
   for i, s in ipairs(out) do
      local nxt = out[i + 1]
      if nxt then
         local ny, nx = nxt.y, nxt.x
         -- end at the end of the last token before the next member
         local idx = ast_walk.token_index_at(tokens, ny, nx) - 1
         local prev = tokens[idx]
         if prev and (prev.y > s.sel_y or (prev.y == s.sel_y and prev.x >= s.sel_x)) then
            s.yend, s.xend = ast_walk.token_end(prev)
         else
            s.yend, s.xend = s.sel_yend, s.sel_xend
         end
      else
         -- last member: up to the token before the parent's closing `end`
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

-- name of the owner of `function Owner.f` / `function Owner:m`
local function owner_name(fn_owner: AstNode): string
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

local function statement_symbol(tokens: {tl.Token}, stmt: AstNode, name_node: AstNode, kind: symbols.Kind): symbols.Symbol
   local y, x = ast_walk.statement_start(tokens, stmt)
   local yend, xend = ast_walk.node_end(tokens, stmt)
   local s: symbols.Symbol = { name = name_node.tk, kind = kind, y = y, x = x, yend = yend, xend = xend }
   sel(s, name_node.y, name_node.x, name_node.tk)
   return s
end

-- Returns the hierarchical outline of a parsed file.
function symbols.document_symbols(tokens: {tl.Token}, ast: AstNode): {symbols.Symbol}
   local out: {symbols.Symbol} = {}
   local by_name: {string:symbols.Symbol} = {}
   if ast == nil then
      return out
   end

   for _, stmt in ipairs(ast) do
      local kind = stmt.kind
      if (kind == "local_type" or kind == "global_type") and stmt.var and stmt.var.tk then
         local nt = stmt.value and stmt.value.newtype as TypeObj
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
            -- replace a declared-only method/field entry with the implementation
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
            -- the implementation lies outside the record body; widen the parent
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

-- Flattens a symbol tree into (symbol, container name) pairs.
function symbols.flatten(list: {symbols.Symbol}, container?: string, out?: {{symbols.Symbol, string}}): {{symbols.Symbol, string}}
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
