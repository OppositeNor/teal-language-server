-- Find references / document highlight / rename support.
--
-- Targets are resolved with compiler data only:
--   * locals and arguments: the declaration found by walking tl's scoped
--     symbol list (Document:symbol_declaration_position); a use refers to the
--     target when it resolves to the same declaration.
--   * globals: uses that resolve to no local declaration, in every open file.
--   * record fields and methods: identified by (record identity, field name),
--     where the record identity is the declaration position of the record type
--     the compiler inferred for the expression left of `.`/`:`. Field
--     declarations come from the outline of the declaring file.
--
-- Positions are tl coordinates (1-based line and byte column, end exclusive).

local tl <const> = require("tl")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local symbols <const> = require("teal_language_server.analysis.symbols")

local type AstNode = ast_walk.AstNode

local record references
   enum TargetKind
      "local"
      "global"
      "field"
      "type"
   end

   record Target
      kind: TargetKind
      name: string
      -- local/type: declaration position in `file`
      decl_y: integer
      decl_x: integer
      file: string
      -- field: identity of the owning record ("file:y:x" or "var:file:y:x")
      owner_key: string
      -- the identifier under the cursor
      y: integer
      x: integer
      yend: integer
      xend: integer
   end

   enum LocationKind
      "decl"
      "write"
      "read"
   end

   record Location
      file: string
      kind: LocationKind
      y: integer
      x: integer
      yend: integer
      xend: integer
   end

   -- what the resolver needs from one analyzed file
   record View
      path: string
      tokens: {tl.Token}
      ast: AstNode
      report: tl.TypeReport
      -- declaration position (1-based) of `name` visible at 0-based (y, x)
      declaration_of: function(name: string, y: integer, x: integer): integer, integer
      symbols: {symbols.Symbol}
   end

   -- loads the outline of a file that may not be open (for field declarations)
   type SymbolLoader = function(path: string): {symbols.Symbol}

   -- normalizes file names found in the type report (may be relative)
   type PathNormalizer = function(path: string): string
end

local type Target = references.Target
local type Location = references.Location
local type View = references.View

local NAME_KINDS <const>: {string:boolean} = {
   variable = true,
   identifier = true,
   argument = true,
   type_identifier = true,
}

local GLOBAL_DECL_KINDS <const>: {string:boolean} = {
   global_declaration = true,
   global_function = true,
   global_type = true,
}

local TYPE_DECL_KINDS <const>: {string:boolean} = {
   local_type = true,
   global_type = true,
}

local function resolve_refs(report: tl.TypeReport, ti: tl.TypeInfo): tl.TypeInfo
   local guard = 0
   while ti and ti.ref and guard < 100 do
      ti = report.types[ti.ref]
      guard = guard + 1
   end
   return ti
end

local function type_at(view: View, y: integer, x: integer): tl.TypeInfo
   local report = view.report
   if report == nil then return nil end
   local file = report.by_pos[view.path]
   local row = file and file[y]
   local id = row and row[x]
   return resolve_refs(report, id and report.types[id])
end

-- Type of an expression node, following function calls through the called
-- function's first return type (tl does not record call results).
local function expr_type(view: View, node: AstNode): tl.TypeInfo
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

-- Per-view index of parents, built lazily.
local parents_cache: {AstNode:{AstNode:AstNode}} = setmetatable({}, { __mode = "k" })

local function parents_of(view: View): {AstNode:AstNode}
   local cached = parents_cache[view.ast]
   if cached then return cached end
   local parents: {AstNode:AstNode} = {}
   ast_walk.walk(view.ast, {
      ["*"] = function(node: AstNode, parent: AstNode)
         parents[node] = parent
      end,
   })
   parents_cache[view.ast] = parents
   return parents
end

local function name_range(node: AstNode): integer, integer, integer, integer
   return node.y, node.x, node.y, node.x + #node.tk
end

-- The statement (direct child of a `statements` block) containing `node`.
local function enclosing_statement(parents: {AstNode:AstNode}, node: AstNode): AstNode
   local cur = node
   while parents[cur] and parents[cur].kind ~= "statements" do
      cur = parents[cur]
   end
   return cur
end

-- If `node` is the field name of a `.`/`:` access, returns the access node.
local function field_access_of(parents: {AstNode:AstNode}, node: AstNode): AstNode
   local p = parents[node]
   if p and p.kind == "op" and p.op and (p.op.op == "." or p.op.op == ":") and p.e2 == node then
      return p
   end
   return nil
end

-- If `node` is the name of `function Owner.name` / `function Owner:name`, returns that node.
local function record_function_of(parents: {AstNode:AstNode}, node: AstNode): AstNode
   local p = parents[node]
   if p and p.kind == "record_function" and p.name == node then
      return p
   end
   return nil
end

-- Position (0-based, for declaration_of) at which a name use should be
-- resolved. Inside the initializer of `local x = <exp>` the new `x` is not yet
-- in scope, but tl's symbol list positions it at the variable, before the
-- expression; resolve such uses from just before the statement instead.
local function lookup_position(view: View, parents: {AstNode:AstNode}, node: AstNode): integer, integer
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

-- Identity of the value left of a field access: the declaring position of its
-- record type, or for untyped module tables, the declaration of the variable.
local function owner_key(view: View, normalize: references.PathNormalizer, node: AstNode, parents: {AstNode:AstNode}): string
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

local function owner_key_of_record_function(view: View, normalize: references.PathNormalizer, fn: AstNode, parents: {AstNode:AstNode}): string
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

-- Finds the record/interface symbol declared at (y, x) in an outline, with the path to it.
local function find_type_symbol(list: {symbols.Symbol}, y: integer, x: integer): symbols.Symbol
   for _, s in ipairs(list or {}) do
      if (s.kind == "Class" or s.kind == "Interface") and s.y == y and s.x == x then
         return s
      end
      local found = find_type_symbol(s.children, y, x)
      if found then return found end
   end
   return nil
end

-- Field declared at the cursor inside a record body: returns (container, field).
local function field_symbol_at(list: {symbols.Symbol}, y: integer, x: integer, container?: symbols.Symbol): symbols.Symbol, symbols.Symbol
   for _, s in ipairs(list or {}) do
      if s.sel_y == y and x >= s.sel_x and x < s.sel_xend and container
         and (container.kind == "Class" or container.kind == "Interface")
         and (s.kind == "Field" or s.kind == "Method") then
         return container, s
      end
      local c, f = field_symbol_at(s.children, y, x, s)
      if c then return c, f end
   end
   return nil, nil
end

local function node_at(view: View, y: integer, x: integer): AstNode
   local found: AstNode
   ast_walk.walk(view.ast, {
      ["*"] = function(node: AstNode)
         if found == nil and NAME_KINDS[node.kind] and node.tk and node.y == y
            and x >= node.x and x < node.x + #node.tk and node.tk:match("^[%a_][%w_]*$") then
            found = node
         end
      end,
   })
   return found
end

-- Resolves what is under the cursor (1-based y, x) in `view`.
function references.resolve_target(view: View, normalize: references.PathNormalizer, y: integer, x: integer): Target
   if view.ast == nil then return nil end
   local parents = parents_of(view)
   local node = node_at(view, y, x)

   if node == nil then
      -- a field declaration inside a record body has no AST node of its own
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

   -- classify by the statement that declares the name
   local kind: references.TargetKind = "local"
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

local function location_kind(parents: {AstNode:AstNode}, node: AstNode, decl_y: integer, decl_x: integer): references.LocationKind
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

local function collect_names(view: View, target: Target, out: {Location})
   local parents = parents_of(view)
   ast_walk.walk(view.ast, {
      ["*"] = function(node: AstNode)
         if not NAME_KINDS[node.kind] or node.tk ~= target.name or node.y == nil then
            return
         end
         if field_access_of(parents, node) or record_function_of(parents, node) then
            return
         end
         local ly, lx = lookup_position(view, parents, node)
         local dy, dx = view.declaration_of(node.tk, ly, lx)
         local matches: boolean
         if target.kind == "global" then
            if dy == nil then
               matches = true
            else
               -- the global's own declaration statement
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
               kind = (target.kind == "global" and dy == node.y and dx == node.x) and "decl"
                  or location_kind(parents, node, target.decl_y or -1, target.decl_x or -1),
               y = y, x = x, yend = yend, xend = xend,
            })
         end
      end,
   })
end

local FUNCTION_KINDS <const>: {string:boolean} = {
   local_function = true,
   global_function = true,
   record_function = true,
   ["function"] = true,
}

local record KeyNode
   conststr: string
   key_parsed: string
end

-- Record type of a table constructor: recorded by tl when the context gives it
-- (annotated variable, argument, array element); for `return { ... }` it is
-- recovered from the enclosing function's declared return type.
local function literal_table_type(view: View, parents: {AstNode:AstNode}, node: AstNode): tl.TypeInfo
   local ti = type_at(view, node.y, node.x)
   if ti then
      return ti
   end
   local list = parents[node]
   local ret = list and parents[list]
   if not (list and list.kind == "expression_list" and ret and ret.kind == "return") then
      return nil
   end
   local index: integer
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

local function record_key(view: View, normalize: references.PathNormalizer, ti: tl.TypeInfo): string
   if ti and (ti.t == tl.typecodes.RECORD or ti.t == tl.typecodes.INTERFACE) and ti.y and ti.x then
      return normalize(ti.file or view.path) .. ":" .. ti.y .. ":" .. ti.x
   end
   return nil
end

local function collect_fields(view: View, normalize: references.PathNormalizer, target: Target, out: {Location}, unresolved: {Location})
   local parents = parents_of(view)
   ast_walk.walk(view.ast, {
      literal_table = function(node: AstNode)
         for _, item in ipairs(node) do
            local key = item.kind == "literal_table_item" and (item as any as {string:any}).key as AstNode
            local k = key and key as any as KeyNode
            if k and (item as any as KeyNode).key_parsed == "short" and k.conststr == target.name and key.y then
               local loc: Location = { file = view.path, kind = "write", y = key.y, x = key.x, yend = key.y, xend = key.x + #target.name }
               local ti = literal_table_type(view, parents, node)
               if ti == nil then
                  table.insert(unresolved, loc)
               elseif record_key(view, normalize, ti) == target.owner_key then
                  table.insert(out, loc)
               end
            end
         end
      end,
      ["*"] = function(node: AstNode)
         if node.kind ~= "identifier" or node.tk ~= target.name or node.y == nil then
            return
         end
         local key: string
         local kind: references.LocationKind = "read"
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

-- Declaration(s) of a record field from the outline of the declaring file: the
-- field declared in the record body and/or its `function R:f` implementation.
local function field_declarations(target: Target, load_symbols: references.SymbolLoader): {Location}
   local out: {Location} = {}
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

-- Where `target` is declared, as references.find reports its "decl"
-- locations: a local or type at its declaration, a field in its record body
-- and/or at its `function R:f` implementation (the record body first).
-- Empty for globals, whose declarations need a search of every file.
function references.declarations(target: Target, load_symbols: references.SymbolLoader): {Location}
   if target.kind == "local" or target.kind == "type" then
      return { { file = target.file, kind = "decl", y = target.decl_y, x = target.decl_x, yend = target.decl_y, xend = target.decl_x + #target.name } }
   elseif target.kind == "field" then
      local decls = field_declarations(target, load_symbols)
      table.sort(decls, function(a: Location, b: Location): boolean
         if a.y ~= b.y then return a.y < b.y end
         return a.x < b.x
      end)
      return decls
   end
   return {}
end

-- Declaring file of a field target's record, or nil for module-table targets.
function references.owner_file(target: Target): string
   if target.owner_key == nil or target.owner_key:sub(1, 4) == "var:" then
      return nil
   end
   return (target.owner_key:match("^(.*):%d+:%d+$"))
end

-- All locations of `target` across `views` (sorted, deduplicated). The second
-- result lists table-constructor keys with the target's name whose table type
-- could not be determined: they may or may not refer to the target.
function references.find(views: {View}, target: Target, normalize: references.PathNormalizer, load_symbols: references.SymbolLoader): {Location}, {Location}
   local out: {Location} = {}
   local unresolved: {Location} = {}
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

   table.sort(out, function(a: Location, b: Location): boolean
      if a.file ~= b.file then return a.file < b.file end
      if a.y ~= b.y then return a.y < b.y end
      if a.x ~= b.x then return a.x < b.x end
      -- prefer the declaration when two entries share a position
      return a.kind == "decl" and b.kind ~= "decl"
   end)
   local dedup: {Location} = {}
   for _, loc in ipairs(out) do
      local last = dedup[#dedup]
      if not (last and last.file == loc.file and last.y == loc.y and last.x == loc.x) then
         table.insert(dedup, loc)
      end
   end
   return dedup, unresolved
end

local LUA_KEYWORDS <const>: {string:boolean} = {
   ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
   ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
   ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
   ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
   ["until"] = true, ["while"] = true,
}

function references.is_valid_name(name: string): boolean
   return name ~= nil and name:match("^[%a_][%w_]*$") ~= nil and not LUA_KEYWORDS[name]
end

return references
