local _module_name = "analysis.workspace_index"

-- Index of the project's Teal files for workspace-wide features
-- (workspace/symbol, require completion).
--
-- Files are parsed only (tl.parse, no type checking), which is cheap and
-- independent of the shared compiler env. The index is refreshed lazily on
-- each query: the directory tree is rescanned and files are re-parsed only when
-- their modification time changed. Open documents use their editor buffers.

local tl <const> = require("tl")
local lfs <const> = require("lfs")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local symbols <const> = require("teal_language_server.analysis.symbols")
local position <const> = require("teal_language_server.util.position")
local logging <const> = require("teal_language_server.logging")

local logger = logging.get_logger(_module_name)

local MAX_FILES <const> = 5000

local SKIP_DIRS <const>: {string:boolean} = {
   [".git"] = true,
   [".hg"] = true,
   [".svn"] = true,
   ["node_modules"] = true,
   ["luarocks_tree"] = true,
   ["lua_modules"] = true,
   [".luarocks"] = true,
}

local record workspace_index
   record Entry
      path: string
      mtime: number
      lines: {string}
      symbols: {symbols.Symbol}
   end

   record Index
      root: string
      -- directories searched for modules, relative to root ("" = root)
      module_roots: {string}
      skip: {string:boolean}
      entries: {string:Entry}
   end

   record Match
      symbol: symbols.Symbol
      container: string
      path: string
      lines: {string}
   end
end

local type Index = workspace_index.Index
local type Entry = workspace_index.Entry

local function is_teal_file(name: string): boolean
   return name:sub(-3) == ".tl"
end

local function scan(dir: string, skip: {string:boolean}, out: {string})
   if #out >= MAX_FILES then
      return
   end
   local names: {string} = {}
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
      -- skips ".", ".." and hidden files/directories
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

-- `module_roots` are the directories modules are resolved from (source_dir,
-- include_dir entries), relative to `root`; `skip_dirs` (e.g. build_dir) are
-- excluded from the scan.
function workspace_index.new(root: string, module_roots: {string}, skip_dirs: {string}): Index
   local skip: {string:boolean} = {}
   for _, d in ipairs(skip_dirs or {}) do
      skip[root .. "/" .. d:gsub("/$", "")] = true
   end
   local roots: {string} = {}
   for _, r in ipairs(module_roots or {}) do
      table.insert(roots, (r:gsub("^%./", ""):gsub("/$", "")))
   end
   table.insert(roots, "")
   return { root = root, module_roots = roots, skip = skip, entries = {} }
end

local function parse_file(path: string, text: string): {symbols.Symbol}
   local tokens = tl.lex(text, path)
   local errs: {tl.Error} = {}
   local ast = tl.parse_program(tokens, errs, path)
   local ok, result = pcall(symbols.document_symbols, tokens, ast as ast_walk.AstNode)
   if not ok then
      logger:warning("Could not index %s: %s", path, tostring(result))
      return {}
   end
   return result as {symbols.Symbol}
end

-- Rescans the workspace. `open_content(path)` returns the buffer text of an
-- open document (unsaved edits win over the file on disk) or nil.
function workspace_index.refresh(index: Index, open_content: function(string): string)
   local files: {string} = {}
   scan(index.root, index.skip, files)
   local seen: {string:boolean} = {}
   for _, path in ipairs(files) do
      seen[path] = true
      local buffer = open_content(path)
      local entry = index.entries[path]
      if buffer then
         if entry == nil or entry.mtime ~= -1 or table.concat(entry.lines, "\n") ~= buffer then
            index.entries[path] = { path = path, mtime = -1, lines = position.split_lines(buffer), symbols = parse_file(path, buffer) }
         end
      else
         local mtime = lfs.attributes(path, "modification") as number
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

-- Case-insensitive subsequence match ("vecnorm" matches "VectorNormalize").
-- Returns a score (lower is better) or nil.
local function match_score(query: string, name: string): integer
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

function workspace_index.query(index: Index, query: string, limit: integer): {workspace_index.Match}
   local record Scored
      match: workspace_index.Match
      score: integer
   end
   local scored: {Scored} = {}
   local paths: {string} = {}
   for path in pairs(index.entries) do
      table.insert(paths, path)
   end
   table.sort(paths)
   for _, path in ipairs(paths) do
      local entry: Entry = index.entries[path]
      for _, pair in ipairs(symbols.flatten(entry.symbols)) do
         local sym, container = pair[1], pair[2]
         local score = match_score(query, sym.name)
         if score then
            table.insert(scored, { score = score, match = { symbol = sym, container = container, path = path, lines = entry.lines } })
         end
      end
   end
   table.sort(scored, function(a: Scored, b: Scored): boolean
      if a.score ~= b.score then return a.score < b.score end
      if #a.match.symbol.name ~= #b.match.symbol.name then return #a.match.symbol.name < #b.match.symbol.name end
      if a.match.path ~= b.match.path then return a.match.path < b.match.path end
      return a.match.symbol.sel_y < b.match.symbol.sel_y
   end)
   local out: {workspace_index.Match} = {}
   for i = 1, math.min(#scored, limit) do
      table.insert(out, scored[i].match)
   end
   return out
end

-- Module names requirable from the indexed files: "a/b.tl" under a module
-- root becomes "a.b"; "a/init.tl" becomes "a". Sorted and unique.
function workspace_index.module_names(index: Index): {string}
   local set: {string:boolean} = {}
   for path in pairs(index.entries) do
      for _, r in ipairs(index.module_roots) do
         local base = r == "" and index.root or (index.root .. "/" .. r)
         if path:sub(1, #base + 1) == base .. "/" then
            local rel = path:sub(#base + 2)
            rel = rel:gsub("%.d%.tl$", ""):gsub("%.tl$", ""):gsub("/init$", "")
            if not rel:find("%.") then
               set[(rel:gsub("/", "."))] = true
            end
            break
         end
      end
   end
   local out: {string} = {}
   for name in pairs(set) do
      table.insert(out, name)
   end
   table.sort(out)
   return out
end

return workspace_index
