local _module_name = "handlers.navigation"

-- Navigation features built on the tl AST and type report: document symbols
-- (outline), references, document highlight and rename.

local handler_helper <const> = require("teal_language_server.handlers.handler_helper")
local DocumentManager <const> = require("teal_language_server.analysis.document_manager")
local Document <const> = require("teal_language_server.analysis.document")
local ServerState <const> = require("teal_language_server.server_state")
local LspReaderWriter <const> = require("teal_language_server.lsp.reader_writer")
local LspEventsManager <const> = require("teal_language_server.lsp.events_manager")
local symbols <const> = require("teal_language_server.analysis.symbols")
local references <const> = require("teal_language_server.analysis.references")
local workspace_index <const> = require("teal_language_server.analysis.workspace_index")
local position <const> = require("teal_language_server.util.position")
local Uri <const> = require("teal_language_server.util.uri")
local lsp <const> = require("teal_language_server.lsp.protocol")
local logging <const> = require("teal_language_server.logging")
local class <const> = require("teal_language_server.util.class")
local json <const> = require("cjson")
local lfs <const> = require("lfs")
local tl <const> = require("tl")
local uv <const> = require("luv")

local logger = logging.get_logger(_module_name)

local record NavigationHandlers
   -- a workspace file that is not open, analyzed to be searched
   record ClosedFile
      doc: Document
      mtime: number
      env: tl.Env
   end

   -- the views of a search, plus the files whose analysis cannot prove the
   -- search complete (syntax errors, a failed check)
   record Scope
      views: {references.View}
      incomplete: {string}
   end

   _closed: {string:ClosedFile}
   _document_manager: DocumentManager
   _server_state: ServerState
   _lsp_reader_writer: LspReaderWriter
   _lsp_events_manager: LspEventsManager

   metamethod __call: function(self: NavigationHandlers, lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, server_state: ServerState, document_manager: DocumentManager): NavigationHandlers
end

function NavigationHandlers:__init(lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, server_state: ServerState, document_manager: DocumentManager)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
   self._document_manager = document_manager
   self._closed = {}
end

local function pos_lt(a: lsp.Position, b: lsp.Position): boolean
   return a.line < b.line or (a.line == b.line and a.character < b.character)
end

local function to_document_symbol(doc: Document, s: symbols.Symbol): {string:any}
   local range = doc:to_lsp_range(s.y, s.x, s.yend, s.xend)
   local selection = doc:to_lsp_range(s.sel_y, s.sel_x, s.sel_yend, s.sel_xend)
   -- LSP requires selectionRange to be contained in range
   if pos_lt(selection.start, range.start) then range.start = selection.start end
   if pos_lt(range["end"], selection["end"]) then range["end"] = selection["end"] end

   local children: {{string:any}} = {}
   for _, c in ipairs(s.children or {}) do
      table.insert(children, to_document_symbol(doc, c))
   end
   setmetatable(children, json.empty_array_mt as metatable<{{string:any}}>)
   return {
      name = s.name,
      detail = s.detail,
      kind = symbols.kind_to_lsp[s.kind],
      range = range,
      selectionRange = selection,
      children = children,
   }
end

function NavigationHandlers:_on_document_symbol(params: lsp.Method.Params, id: integer)
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end
   local result: {{string:any}} = {}
   for _, s in ipairs(doc:get_symbols()) do
      table.insert(result, to_document_symbol(doc, s))
   end
   logger:debug("Returning %d top-level symbols", #result)
   setmetatable(result, json.empty_array_mt as metatable<{{string:any}}>)
   self._lsp_reader_writer:send_rpc(id, result as {string:any})
end

function NavigationHandlers:_normalize(path: string): string
   return self._server_state:absolute_path(path)
end

function NavigationHandlers:_open_doc(path: string): Document
   return self._document_manager:get(Uri.uri_from_path(path))
end

function NavigationHandlers:_load_symbols(path: string): {symbols.Symbol}
   return handler_helper.load_symbols(self._document_manager, path)
end

function NavigationHandlers:_view(doc: Document): references.View
   return handler_helper.view(doc)
end

-- A workspace file that is not open, type checked in the shared env. Kept
-- while the file's mtime and the env are unchanged; nil if unreadable.
function NavigationHandlers:_closed_doc(path: string): Document
   local mtime = lfs.attributes(path, "modification") as number
   local env = self._server_state:get_env()
   local cached = self._closed[path]
   if cached and cached.mtime == mtime and cached.env == env then
      return cached.doc
   end
   local fd = io.open(path, "rb")
   if not fd then
      self._closed[path] = nil
      return nil
   end
   local text = fd:read("*a")
   fd:close()
   local doc = Document(Uri.uri_from_path(path), text, 0, self._lsp_reader_writer, self._server_state)
   self._closed[path] = { doc = doc, mtime = mtime, env = env }
   return doc
end

-- Upper bound on closed files type checked for one search, and on the size
-- of one: tl's checker cannot be interrupted, so the time budget below is
-- only checked between files
local MAX_CLOSED_FILES <const> = 200
local MAX_CLOSED_FILE_BYTES <const> = 256 * 1024

-- Time budget for type checking closed files in one search, from
-- tlconfig.lua `externals.teal_language_server.references_budget_ms`.
function NavigationHandlers:_search_budget_ms(): number
   local externals = (self._server_state.config or {}).externals
   local ours = externals and (externals as {string:any}).teal_language_server
   local value = type(ours) == "table" and (ours as {string:any}).references_budget_ms
   if type(value) == "number" and value as number >= 0 then
      return value as number
   end
   return 1500
end

-- Where to look for `target`. A local or type lives in the current file. A
-- global or record field can be used anywhere: every open document, plus the
-- workspace files that are not open and contain the name as a whole word
-- (a cheap text filter; each hit is then confirmed semantically by the
-- resolver, as in rust-analyzer's FindUsages and TypeScript's name table).
function NavigationHandlers:_scope_for(target: references.Target, current: Document): NavigationHandlers.Scope
   if target.kind == "local" or target.kind == "type" then
      return { views = { self:_view(current) }, incomplete = {} }
   end
   local scope: NavigationHandlers.Scope = { views = {}, incomplete = {} }
   local paths: {string} = {}
   for path in pairs(self._document_manager.docs) do
      table.insert(paths, path)
   end
   table.sort(paths)
   for _, path in ipairs(paths) do
      table.insert(scope.views, self:_view(self._document_manager.docs[path]))
   end

   local index = self._server_state:get_workspace_index()
   workspace_index.refresh(index, function(path: string): string
      return self._document_manager:open_content(path)
   end)
   local pattern = "%f[%w_]" .. target.name .. "%f[^%w_]"
   local closed: {string} = {}
   for path, entry in pairs(index.entries) do
      if entry.mtime ~= -1 and not self._document_manager.docs[path] then
         for _, line in ipairs(entry.lines) do
            if line:find(pattern) then
               table.insert(closed, path)
               break
            end
         end
      end
   end
   table.sort(closed)
   -- files already analyzed for this env are free; new ones are checked
   -- until the budget runs out, and the rest are reported as not searched
   local deadline = uv.hrtime() + self:_search_budget_ms() * 1e6
   local env = self._server_state:get_env()
   for i, path in ipairs(closed) do
      local cached = self._closed[path]
      local is_cached = cached ~= nil and cached.env == env
         and cached.mtime == lfs.attributes(path, "modification") as number
      local too_big = (lfs.attributes(path, "size") as number or 0) > MAX_CLOSED_FILE_BYTES
      if i > MAX_CLOSED_FILES or too_big or (not is_cached and uv.hrtime() > deadline) then
         table.insert(scope.incomplete, path)
      else
         local doc = self:_closed_doc(path)
         local ok, view = pcall(handler_helper.view, doc, true)
         if doc and ok and doc:ensure_semantics() then
            table.insert(scope.views, view as references.View)
            if doc:is_recovered() then
               table.insert(scope.incomplete, path)
            end
         else
            table.insert(scope.incomplete, path)
         end
      end
   end
   return scope
end

-- Resolves the target under the request position, plus the current document.
function NavigationHandlers:_target(params: lsp.Method.Params): references.Target, Document
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      return nil, nil
   end
   local pos = handler_helper.byte_position(self._document_manager, params)
   local normalize = function(p: string): string return self:_normalize(p) end
   local target = references.resolve_target(self:_view(doc), normalize, pos.line + 1, pos.character + 1)
   return target, doc
end

-- Locations of `target`, the unresolved constructor keys (see
-- references.find) and the files where the search may be incomplete.
function NavigationHandlers:_find(target: references.Target, doc: Document): {references.Location}, {references.Location}, {string}
   local normalize = function(p: string): string return self:_normalize(p) end
   local loader = function(p: string): {symbols.Symbol} return self:_load_symbols(p) end
   local scope = self:_scope_for(target, doc)
   local locations, unresolved = references.find(scope.views, target, normalize, loader)
   return locations, unresolved, scope.incomplete
end

-- Is `path` inside the workspace root?
function NavigationHandlers:_in_workspace(path: string): boolean
   local root = self._server_state.teal_project_root_dir
   if root == nil then
      return false
   end
   local prefix = root.value:gsub("/$", "") .. "/"
   return path:sub(1, #prefix) == prefix
end

function NavigationHandlers:_lsp_range(file: string, y: integer, x: integer, yend: integer, xend: integer): lsp.Range
   local doc = self:_open_doc(file)
   if doc then
      return doc:to_lsp_range(y, x, yend, xend)
   end
   local line = position.read_file_line(file, y - 1)
   local end_line = yend == y and line or position.read_file_line(file, yend - 1)
   return {
      start = lsp.position(y - 1, position.byte_to_utf16(line, x - 1)),
      ["end"] = lsp.position(yend - 1, position.byte_to_utf16(end_line, xend - 1)),
   }
end

function NavigationHandlers:_on_references(params: lsp.Method.Params, id: integer)
   local target, doc = self:_target(params)
   local result: {{string:any}} = {}
   if target then
      local context = (params.context or {}) as {string:any}
      local include_decl = context.includeDeclaration ~= false
      for _, loc in ipairs((self:_find(target, doc))) do
         if include_decl or loc.kind ~= "decl" then
            table.insert(result, {
               uri = Uri.tostring(Uri.uri_from_path(loc.file)),
               range = self:_lsp_range(loc.file, loc.y, loc.x, loc.yend, loc.xend),
            })
         end
      end
   end
   setmetatable(result, json.empty_array_mt as metatable<{{string:any}}>)
   self._lsp_reader_writer:send_rpc(id, result as {string:any})
end

local highlight_kind: {references.LocationKind:integer} = {
   decl = 3, -- Write
   write = 3,
   read = 2, -- Read
}

function NavigationHandlers:_on_document_highlight(params: lsp.Method.Params, id: integer)
   local target, doc = self:_target(params)
   local result: {{string:any}} = {}
   if target then
      for _, loc in ipairs((self:_find(target, doc))) do
         if loc.file == doc.uri.path then
            table.insert(result, {
               range = doc:to_lsp_range(loc.y, loc.x, loc.yend, loc.xend),
               kind = highlight_kind[loc.kind],
            })
         end
      end
   end
   setmetatable(result, json.empty_array_mt as metatable<{{string:any}}>)
   self._lsp_reader_writer:send_rpc(id, result as {string:any})
end

-- Returns the target and its locations if it can be renamed, otherwise nil and
-- a message explaining why.
function NavigationHandlers:_rename_plan(params: lsp.Method.Params): references.Target, Document, {references.Location}, string
   local target, doc = self:_target(params)
   if target == nil then
      return nil, nil, nil, "No renameable symbol at this position"
   end
   if target.kind == "type" then
      return nil, nil, nil, "Renaming types is not supported yet: uses in type annotations are not tracked"
   end
   local locations, unresolved, incomplete = self:_find(target, doc)
   if #incomplete > 0 then
      return nil, nil, nil, string.format("Cannot safely rename '%s': %s could not be fully analyzed (syntax errors, or too many files to check)",
         target.name, incomplete[1])
   end
   if #unresolved > 0 then
      local u = unresolved[1]
      return nil, nil, nil, string.format("Cannot safely rename '%s': the table constructor key at %s:%d:%d could not be typed; annotate the table's type and retry",
         target.name, u.file, u.y, u.x)
   end
   if target.kind == "global" then
      local declared = false
      for _, loc in ipairs(locations) do
         if loc.kind == "decl" then declared = true end
      end
      if not declared then
         return nil, nil, nil, string.format("Cannot rename '%s': it is not declared in the workspace", target.name)
      end
   end
   if target.kind == "field" and references.owner_file(target) then
      local declared = false
      for _, loc in ipairs(locations) do
         if loc.kind == "decl" then declared = true end
      end
      if not declared then
         return nil, nil, nil, string.format("Cannot rename '%s': its declaration was not found", target.name)
      end
   end
   for _, loc in ipairs(locations) do
      if not self:_open_doc(loc.file) and not self:_in_workspace(loc.file) then
         return nil, nil, nil, string.format("Cannot rename '%s': %s is outside the workspace", target.name, loc.file)
      end
   end
   return target, doc, locations, nil
end

function NavigationHandlers:_on_prepare_rename(params: lsp.Method.Params, id: integer)
   local target, doc, _, err = self:_rename_plan(params)
   if target == nil then
      self._lsp_reader_writer:send_rpc_error(id, "RequestFailed", err)
      return
   end
   self._lsp_reader_writer:send_rpc(id, {
      range = doc:to_lsp_range(target.y, target.x, target.yend, target.xend),
      placeholder = target.name,
   })
end

function NavigationHandlers:_on_rename(params: lsp.Method.Params, id: integer)
   local new_name = params.newName as string
   if not references.is_valid_name(new_name) then
      self._lsp_reader_writer:send_rpc_error(id, "InvalidParams", string.format("'%s' is not a valid Teal identifier", tostring(new_name)))
      return
   end
   local target, _, locations, err = self:_rename_plan(params)
   if target == nil then
      self._lsp_reader_writer:send_rpc_error(id, "RequestFailed", err)
      return
   end

   local by_file: {string:{{string:any}}} = {}
   local files: {string} = {}
   for _, loc in ipairs(locations) do
      if not by_file[loc.file] then
         by_file[loc.file] = {}
         table.insert(files, loc.file)
      end
      table.insert(by_file[loc.file], {
         range = self:_lsp_range(loc.file, loc.y, loc.x, loc.yend, loc.xend),
         newText = new_name,
      })
   end

   local edit: {string:any}
   if self._server_state:client_capability("workspace", "workspaceEdit", "documentChanges") then
      local changes: {{string:any}} = {}
      for _, file in ipairs(files) do
         local d = self:_open_doc(file)
         -- a file that is not open has no version to check against
         local version: any = json.null
         if d then
            version = d.version
         end
         table.insert(changes, {
            textDocument = { uri = Uri.tostring(Uri.uri_from_path(file)), version = version },
            edits = by_file[file],
         })
      end
      edit = { documentChanges = changes }
   else
      local changes: {string:{{string:any}}} = {}
      for _, file in ipairs(files) do
         changes[Uri.tostring(Uri.uri_from_path(file))] = by_file[file]
      end
      edit = { changes = changes }
   end
   self._lsp_reader_writer:send_rpc(id, edit)
end

function NavigationHandlers:_on_workspace_symbol(params: lsp.Method.Params, id: integer)
   local query = (params.query or "") as string
   local index = self._server_state:get_workspace_index()
   workspace_index.refresh(index, function(path: string): string
      return self._document_manager:open_content(path)
   end)
   local result: {{string:any}} = {}
   for _, m in ipairs(workspace_index.query(index, query, 200)) do
      local s = m.symbol
      local line = m.lines[s.sel_y] or ""
      table.insert(result, {
         name = s.name,
         kind = symbols.kind_to_lsp[s.kind],
         containerName = m.container,
         location = {
            uri = Uri.tostring(Uri.uri_from_path(m.path)),
            range = {
               start = lsp.position(s.sel_y - 1, position.byte_to_utf16(line, s.sel_x - 1)),
               ["end"] = lsp.position(s.sel_yend - 1, position.byte_to_utf16(line, s.sel_xend - 1)),
            },
         },
      })
   end
   setmetatable(result, json.empty_array_mt as metatable<{{string:any}}>)
   self._lsp_reader_writer:send_rpc(id, result as {string:any})
end

function NavigationHandlers:initialize()
   self._lsp_events_manager:set_handler("textDocument/documentSymbol", function(params: lsp.Method.Params, id: integer) self:_on_document_symbol(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/references", function(params: lsp.Method.Params, id: integer) self:_on_references(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/documentHighlight", function(params: lsp.Method.Params, id: integer) self:_on_document_highlight(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/prepareRename", function(params: lsp.Method.Params, id: integer) self:_on_prepare_rename(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/rename", function(params: lsp.Method.Params, id: integer) self:_on_rename(params, id) end)
   self._lsp_events_manager:set_handler("workspace/symbol", function(params: lsp.Method.Params, id: integer) self:_on_workspace_symbol(params, id) end)
end

class.setup(NavigationHandlers, "NavigationHandlers", {})

return NavigationHandlers
