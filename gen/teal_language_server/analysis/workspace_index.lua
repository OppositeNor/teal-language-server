local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local _module_name = "analysis.workspace_index"









local tl = require("tl")
local lfs = require("lfs")
local uv = require("luv")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local symbols = require("teal_language_server.analysis.symbols")
local position = require("teal_language_server.util.position")
local logging = require("teal_language_server.logging")

local logger = logging.get_logger(_module_name)

local MAX_FILES = 5000

local SKIP_DIRS = {
   [".git"] = true,
   [".hg"] = true,
   [".svn"] = true,
   ["node_modules"] = true,
   ["luarocks_tree"] = true,
   ["lua_modules"] = true,
   [".luarocks"] = true,
}

local workspace_index = { Entry = {}, Index = {}, Module = {}, Match = {} }

































local function is_teal_file(name)
   return name:sub(-3) == ".tl"
end

local function scan(dir, skip, out)
   if #out >= MAX_FILES then
      return
   end
   local names = {}
   local ok = pcall(function()
      for name in lfs.dir(dir) do
         table.insert(names, name)
      end
   end)
   if not ok then
      return
   end
   table.sort(names)
   for _, name in ipairs(names) do

      if name:sub(1, 1) ~= "." then
         local full = dir .. "/" .. name
         local mode = lfs.attributes(full, "mode")
         if mode == "directory" then
            if not SKIP_DIRS[name] and not skip[full] then
               scan(full, skip, out)
            end
         elseif mode == "file" and is_teal_file(name) then
            table.insert(out, full)
         end
      end
   end
end




function workspace_index.new(root, module_roots, skip_dirs)
   local skip = {}
   for _, d in ipairs(skip_dirs or {}) do
      skip[root .. "/" .. d:gsub("/$", "")] = true
   end
   local roots = {}
   for _, r in ipairs(module_roots or {}) do
      table.insert(roots, (r:gsub("^%./", ""):gsub("/$", "")))
   end
   table.insert(roots, "")
   return { root = root, module_roots = roots, skip = skip, entries = {} }
end

local function parse_file(path, text)
   local tokens = tl.lex(text, path)
   local errs = {}
   local ast = ast_walk.parse_program(tokens, errs, path)
   local ok, result = pcall(symbols.document_symbols, tokens, ast)
   if not ok then
      logger:warning("Could not index %s: %s", path, tostring(result))
      return {}
   end
   return result
end



function workspace_index.refresh(index, open_content)
   index.refreshed_at = uv.now()
   local files = {}
   scan(index.root, index.skip, files)
   local seen = {}
   for _, path in ipairs(files) do
      seen[path] = true
      local buffer = open_content(path)
      local entry = index.entries[path]
      if buffer then
         if entry == nil or entry.mtime ~= -1 or table.concat(entry.lines, "\n") ~= buffer then
            index.entries[path] = { path = path, mtime = -1, lines = position.split_lines(buffer), symbols = parse_file(path, buffer) }
         end
      else
         local mtime = lfs.attributes(path, "modification")
         if entry == nil or entry.mtime ~= mtime then
            local fd = io.open(path, "rb")
            if fd then
               local text = fd:read("*a")
               fd:close()
               index.entries[path] = { path = path, mtime = mtime, lines = position.split_lines(text), symbols = parse_file(path, text) }
            end
         end
      end
   end
   for path in pairs(index.entries) do
      if not seen[path] then
         index.entries[path] = nil
      end
   end
end



function workspace_index.refresh_if_stale(index, open_content, max_age_ms)
   if index.refreshed_at == nil or uv.now() - index.refreshed_at >= max_age_ms then
      workspace_index.refresh(index, open_content)
   end
end



local function match_score(query, name)
   if query == "" then
      return 1000
   end
   local q, n = query:lower(), name:lower()
   if n == q then return 0 end
   if n:sub(1, #q) == q then return 1 end
   if n:find(q, 1, true) then return 2 end
   local i = 1
   for c in q:gmatch(".") do
      local found = n:find(c, i, true)
      if not found then
         return nil
      end
      i = found + 1
   end
   return 3
end

function workspace_index.query(index, query, limit)




   local scored = {}
   local paths = {}
   for path in pairs(index.entries) do
      table.insert(paths, path)
   end
   table.sort(paths)
   for _, path in ipairs(paths) do
      local entry = index.entries[path]
      for _, pair in ipairs(symbols.flatten(entry.symbols)) do
         local sym, container = pair[1], pair[2]
         local score = match_score(query, sym.name)
         if score then
            table.insert(scored, { score = score, match = { symbol = sym, container = container, path = path, lines = entry.lines } })
         end
      end
   end
   table.sort(scored, function(a, b)
      if a.score ~= b.score then return a.score < b.score end
      if #a.match.symbol.name ~= #b.match.symbol.name then return #a.match.symbol.name < #b.match.symbol.name end
      if a.match.path ~= b.match.path then return a.match.path < b.match.path end
      return a.match.symbol.sel_y < b.match.symbol.sel_y
   end)
   local out = {}
   for i = 1, math.min(#scored, limit) do
      table.insert(out, scored[i].match)
   end
   return out
end





function workspace_index.modules(index)
   local by_name = {}
   for path in pairs(index.entries) do
      for _, r in ipairs(index.module_roots) do
         local base = r == "" and index.root or (index.root .. "/" .. r)
         if path:sub(1, #base + 1) == base .. "/" then
            local rel = path:sub(#base + 2)
            rel = rel:gsub("%.d%.tl$", ""):gsub("%.tl$", ""):gsub("/init$", "")
            if not rel:find("%.") then
               local name = rel:gsub("/", ".")

               if by_name[name] == nil or path < by_name[name] then
                  by_name[name] = path
               end
            end
            break
         end
      end
   end
   local out = {}
   for name, path in pairs(by_name) do
      table.insert(out, { name = name, path = path })
   end
   table.sort(out, function(a, b) return a.name < b.name end)
   return out
end

function workspace_index.module_names(index)
   local out = {}
   for _, m in ipairs(workspace_index.modules(index)) do
      table.insert(out, m.name)
   end
   return out
end

return workspace_index
