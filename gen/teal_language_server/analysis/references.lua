local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table













local tl = require("tl")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local symbols = require("teal_language_server.analysis.symbols")



local references = { Target = {}, Location = {}, View = {} }




























































local NAME_KINDS = {
   variable = true,
   identifier = true,
   argument = true,
   type_identifier = true,
}

local GLOBAL_DECL_KINDS = {
   global_declaration = true,
   global_function = true,
   global_type = true,
}

local TYPE_DECL_KINDS = {
   local_type = true,
   global_type = true,
}

local function resolve_refs(report, ti)
   local guard = 0
   while ti and ti.ref and guard < 100 do
      ti = report.types[ti.ref]
      guard = guard + 1
   end
   return ti
end

local function type_at(view, y, x)
   local report = view.report
   if report == nil then return nil end
   local file = report.by_pos[view.path]
   local row = file and file[y]
   local id = row and row[x]
   return resolve_refs(report, id and report.types[id])
end



local function expr_type(view, node)
   if node == nil then return nil end
   if node.kind == "paren" then
      return expr_type(view, node.e1)
   end
   if node.kind == "op" and node.op and node.op.op == "@funcall" then
      local fn = expr_type(view, node.e1)
      if fn and fn.t == tl.typecodes.FUNCTION and fn.rets and fn.rets[1] then
         return resolve_refs(view.report, view.report.types[fn.rets[1][1]])
      end
      return nil
   end
   return type_at(view, node.y, node.x)
end


local parents_cache = setmetatable({}, { __mode = "k" })

local function parents_of(view)
   local cached = parents_cache[view.ast]
   if cached then return cached end
   local parents = {}
   ast_walk.walk(view.ast, {
      ["*"] = function(node, parent)
         parents[node] = parent
      end,
   })
   parents_cache[view.ast] = parents
   return parents
end

local function name_range(node)
   return node.y, node.x, node.y, node.x + #node.tk
end


local function enclosing_statement(parents, node)
   local cur = node
   while parents[cur] and parents[cur].kind ~= "statements" do
      cur = parents[cur]
   end
   return cur
end


local function field_access_of(parents, node)
   local p = parents[node]
   if p and p.kind == "op" and p.op and (p.op.op == "." or p.op.op == ":") and p.e2 == node then
      return p
   end
   return nil
end


local function record_function_of(parents, node)
   local p = parents[node]
   if p and p.kind == "record_function" and p.name == node then
      return p
   end
   return nil
end





local function lookup_position(view, parents, node)
   local cur = node
   while parents[cur] do
      local p = parents[cur]
      if (p.kind == "local_declaration" or p.kind == "global_declaration") and p.exps == cur then
         for _, var in ipairs(p.vars or {}) do
            if var.tk == node.tk then
               local sy, sx = ast_walk.statement_start(view.tokens, p)
               if sx > 1 then
                  return sy - 1, sx - 2
               end
               return sy - 2, 100000
            end
         end
      end
      cur = p
   end
   return node.y - 1, node.x - 1
end



local function owner_key(view, normalize, node, parents)
   local ti = expr_type(view, node)
   if ti and (ti.t == tl.typecodes.RECORD or ti.t == tl.typecodes.INTERFACE) and ti.y and ti.x then
      return normalize(ti.file or view.path) .. ":" .. ti.y .. ":" .. ti.x
   end
   if node and node.kind == "variable" then
      local ly, lx = lookup_position(view, parents, node)
      local dy, dx = view.declaration_of(node.tk, ly, lx)
      if dy then
         return "var:" .. view.path .. ":" .. dy .. ":" .. dx
      end
   end
   return nil
end

local function owner_key_of_record_function(view, normalize, fn, parents)
   local owner = fn.fn_owner
   if owner == nil then return nil end
   local ti = type_at(view, owner.y, owner.x)
   if ti and (ti.t == tl.typecodes.RECORD or ti.t == tl.typecodes.INTERFACE) and ti.y then
      return normalize(ti.file or view.path) .. ":" .. ti.y .. ":" .. ti.x
   end
   if owner.kind == "type_identifier" or owner.kind == "variable" then
      local dy, dx = view.declaration_of(owner.tk, owner.y - 1, owner.x - 1)
      if dy then
         return "var:" .. view.path .. ":" .. dy .. ":" .. dx
      end
   end
   return owner_key(view, normalize, owner, parents)
end


local function find_type_symbol(list, y, x)
   for _, s in ipairs(list or {}) do
      if (s.kind == "Class" or s.kind == "Interface") and s.y == y and s.x == x then
         return s
      end
      local found = find_type_symbol(s.children, y, x)
      if found then return found end
   end
   return nil
end


local function field_symbol_at(list, y, x, container)
   for _, s in ipairs(list or {}) do
      if s.sel_y == y and x >= s.sel_x and x < s.sel_xend and container and
         (container.kind == "Class" or container.kind == "Interface") and
         (s.kind == "Field" or s.kind == "Method") then
         return container, s
      end
      local c, f = field_symbol_at(s.children, y, x, s)
      if c then return c, f end
   end
   return nil, nil
end

local function node_at(view, y, x)
   local found
   ast_walk.walk(view.ast, {
      ["*"] = function(node)
         if found == nil and NAME_KINDS[node.kind] and node.tk and node.y == y and
            x >= node.x and x < node.x + #node.tk and node.tk:match("^[%a_][%w_]*$") then
            found = node
         end
      end,
   })
   return found
end


function references.resolve_target(view, normalize, y, x)
   if view.ast == nil then return nil end
   local parents = parents_of(view)
   local node = node_at(view, y, x)

   if node == nil then

      local container, field = field_symbol_at(view.symbols, y, x)
      if container then
         return {
            kind = "field",
            name = field.name,
            owner_key = normalize(view.path) .. ":" .. container.y .. ":" .. container.x,
            y = field.sel_y, x = field.sel_x, yend = field.sel_yend, xend = field.sel_xend,
         }
      end
      return nil
   end

   local ny, nx, nyend, nxend = name_range(node)
   local access = field_access_of(parents, node)
   if access then
      local key = owner_key(view, normalize, access.e1, parents)
      if key == nil then return nil end
      return { kind = "field", name = node.tk, owner_key = key, y = ny, x = nx, yend = nyend, xend = nxend }
   end

   local fn = record_function_of(parents, node)
   if fn then
      local key = owner_key_of_record_function(view, normalize, fn, parents)
      if key == nil then return nil end
      return { kind = "field", name = node.tk, owner_key = key, y = ny, x = nx, yend = nyend, xend = nxend }
   end

   local ly, lx = lookup_position(view, parents, node)
   local dy, dx = view.declaration_of(node.tk, ly, lx)
   if dy == nil then
      return { kind = "global", name = node.tk, y = ny, x = nx, yend = nyend, xend = nxend }
   end


   local kind = "local"
   local decl_node = node_at(view, dy, dx)
   if decl_node then
      local stmt = enclosing_statement(parents, decl_node)
      if stmt and GLOBAL_DECL_KINDS[stmt.kind] then
         kind = "global"
      end
      if stmt and TYPE_DECL_KINDS[stmt.kind] and stmt.var == decl_node then
         kind = "type"
      end
   end
   return { kind = kind, name = node.tk, decl_y = dy, decl_x = dx, file = view.path, y = ny, x = nx, yend = nyend, xend = nxend }
end

local function location_kind(parents, node, decl_y, decl_x)
   if node.y == decl_y and node.x == decl_x then
      return "decl"
   end
   if node.kind == "variable" and node.is_lvalue then
      return "write"
   end
   local p = parents[node]
   if p and p.kind == "op" and p.e2 == node and node.is_lvalue then
      return "write"
   end
   return "read"
end

local function collect_names(view, target, out)
   local parents = parents_of(view)
   ast_walk.walk(view.ast, {
      ["*"] = function(node)
         if not NAME_KINDS[node.kind] or node.tk ~= target.name or node.y == nil then
            return
         end
         if field_access_of(parents, node) or record_function_of(parents, node) then
            return
         end
         local ly, lx = lookup_position(view, parents, node)
         local dy, dx = view.declaration_of(node.tk, ly, lx)
         local matches
         if target.kind == "global" then
            if dy == nil then
               matches = true
            else

               local decl_node = node_at(view, dy, dx)
               local stmt = decl_node and enclosing_statement(parents, decl_node)
               matches = stmt ~= nil and GLOBAL_DECL_KINDS[stmt.kind] == true
            end
         else
            matches = view.path == target.file and dy == target.decl_y and dx == target.decl_x
         end
         if matches then
            local y, x, yend, xend = name_range(node)
            table.insert(out, {
               file = view.path,
               kind = (target.kind == "global" and dy == node.y and dx == node.x) and "decl" or
               location_kind(parents, node, target.decl_y or -1, target.decl_x or -1),
               y = y, x = x, yend = yend, xend = xend,
            })
         end
      end,
   })
end

local FUNCTION_KINDS = {
   local_function = true,
   global_function = true,
   record_function = true,
   ["function"] = true,
}









local function literal_table_type(view, parents, node)
   local ti = type_at(view, node.y, node.x)
   if ti then
      return ti
   end
   local list = parents[node]
   local ret = list and parents[list]
   if not (list and list.kind == "expression_list" and ret and ret.kind == "return") then
      return nil
   end
   local index
   for i, e in ipairs(list) do
      if e == node then index = i end
   end
   local cur = ret
   while cur and not FUNCTION_KINDS[cur.kind] do
      cur = parents[cur]
   end
   if cur == nil or index == nil then
      return nil
   end
   local fn = type_at(view, cur.y, cur.x)
   if fn and fn.t == tl.typecodes.FUNCTION and fn.rets and fn.rets[index] then
      return resolve_refs(view.report, view.report.types[fn.rets[index][1]])
   end
   return nil
end

local function record_key(view, normalize, ti)
   if ti and (ti.t == tl.typecodes.RECORD or ti.t == tl.typecodes.INTERFACE) and ti.y and ti.x then
      return normalize(ti.file or view.path) .. ":" .. ti.y .. ":" .. ti.x
   end
   return nil
end

local function collect_fields(view, normalize, target, out, unresolved)
   local parents = parents_of(view)
   ast_walk.walk(view.ast, {
      literal_table = function(node)
         for _, item in ipairs(node) do
            local key = item.kind == "literal_table_item" and (item).key
            local k = key and key
            if k and (item).key_parsed == "short" and k.conststr == target.name and key.y then
               local loc = { file = view.path, kind = "write", y = key.y, x = key.x, yend = key.y, xend = key.x + #target.name }
               local ti = literal_table_type(view, parents, node)
               if ti == nil then
                  table.insert(unresolved, loc)
               elseif record_key(view, normalize, ti) == target.owner_key then
                  table.insert(out, loc)
               end
            end
         end
      end,
      ["*"] = function(node)
         if node.kind ~= "identifier" or node.tk ~= target.name or node.y == nil then
            return
         end
         local key
         local kind = "read"
         local access = field_access_of(parents, node)
         if access then
            key = owner_key(view, normalize, access.e1, parents)
            if node.is_lvalue or access.is_lvalue then
               kind = "write"
            end
         else
            local fn = record_function_of(parents, node)
            if fn then
               key = owner_key_of_record_function(view, normalize, fn, parents)
               kind = "write"
            end
         end
         if key ~= nil and key == target.owner_key then
            local y, x, yend, xend = name_range(node)
            table.insert(out, { file = view.path, kind = kind, y = y, x = x, yend = yend, xend = xend })
         end
      end,
   })
end



local function field_declarations(target, load_symbols)
   local out = {}
   local file, y, x = target.owner_key:match("^(.*):(%d+):(%d+)$")
   if file == nil or file:sub(1, 4) == "var:" then
      return out
   end
   local outline = load_symbols(file)
   local owner = find_type_symbol(outline, math.tointeger(tonumber(y)), math.tointeger(tonumber(x)))
   if owner == nil then
      return out
   end
   for _, child in ipairs(owner.children or {}) do
      if child.name == target.name and (child.kind == "Field" or child.kind == "Method" or child.kind == "Function") then
         table.insert(out, { file = file, kind = "decl", y = child.sel_y, x = child.sel_x, yend = child.sel_yend, xend = child.sel_xend })
         local d = child.declaration
         if d then
            table.insert(out, { file = file, kind = "decl", y = d.sel_y, x = d.sel_x, yend = d.sel_yend, xend = d.sel_xend })
         end
      end
   end
   return out
end


function references.owner_file(target)
   if target.owner_key == nil or target.owner_key:sub(1, 4) == "var:" then
      return nil
   end
   return (target.owner_key:match("^(.*):%d+:%d+$"))
end




function references.find(views, target, normalize, load_symbols)
   local out = {}
   local unresolved = {}
   for _, view in ipairs(views) do
      if view.ast then
         if target.kind == "field" then
            collect_fields(view, normalize, target, out, unresolved)
         elseif target.kind == "global" or view.path == target.file then
            collect_names(view, target, out)
         end
      end
   end
   if target.kind == "field" then
      for _, decl in ipairs(field_declarations(target, load_symbols)) do
         table.insert(out, decl)
      end
   end

   table.sort(out, function(a, b)
      if a.file ~= b.file then return a.file < b.file end
      if a.y ~= b.y then return a.y < b.y end
      if a.x ~= b.x then return a.x < b.x end

      return a.kind == "decl" and b.kind ~= "decl"
   end)
   local dedup = {}
   for _, loc in ipairs(out) do
      local last = dedup[#dedup]
      if not (last and last.file == loc.file and last.y == loc.y and last.x == loc.x) then
         table.insert(dedup, loc)
      end
   end
   return dedup, unresolved
end

local LUA_KEYWORDS = {
   ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
   ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
   ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
   ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
   ["until"] = true, ["while"] = true,
}

function references.is_valid_name(name)
   return name ~= nil and name:match("^[%a_][%w_]*$") ~= nil and not LUA_KEYWORDS[name]
end

return references
