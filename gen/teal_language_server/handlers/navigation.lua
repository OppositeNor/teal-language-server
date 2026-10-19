local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local _module_name = "handlers.navigation"




local handler_helper = require("teal_language_server.handlers.handler_helper")
local DocumentManager = require("teal_language_server.analysis.document_manager")
local Document = require("teal_language_server.analysis.document")
local ServerState = require("teal_language_server.server_state")
local LspReaderWriter = require("teal_language_server.lsp.reader_writer")
local LspEventsManager = require("teal_language_server.lsp.events_manager")
local symbols = require("teal_language_server.analysis.symbols")
local references = require("teal_language_server.analysis.references")
local workspace_index = require("teal_language_server.analysis.workspace_index")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local position = require("teal_language_server.util.position")
local Uri = require("teal_language_server.util.uri")
local tl = require("tl")
local lsp = require("teal_language_server.lsp.protocol")
local logging = require("teal_language_server.logging")
local class = require("teal_language_server.util.class")
local json = require("cjson")

local logger = logging.get_logger(_module_name)

local NavigationHandlers = {}








function NavigationHandlers:__init(lsp_events_manager, lsp_reader_writer, server_state, document_manager)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
   self._document_manager = document_manager
end

local function pos_lt(a, b)
   return a.line < b.line or (a.line == b.line and a.character < b.character)
end

local function to_document_symbol(doc, s)
   local range = doc:to_lsp_range(s.y, s.x, s.yend, s.xend)
   local selection = doc:to_lsp_range(s.sel_y, s.sel_x, s.sel_yend, s.sel_xend)

   if pos_lt(selection.start, range.start) then range.start = selection.start end
   if pos_lt(range["end"], selection["end"]) then range["end"] = selection["end"] end

   local children = {}
   for _, c in ipairs(s.children or {}) do
      table.insert(children, to_document_symbol(doc, c))
   end
   setmetatable(children, json.empty_array_mt)
   return {
      name = s.name,
      detail = s.detail,
      kind = symbols.kind_to_lsp[s.kind],
      range = range,
      selectionRange = selection,
      children = children,
   }
end

function NavigationHandlers:_on_document_symbol(params, id)
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end
   local result = {}
   for _, s in ipairs(doc:get_symbols()) do
      table.insert(result, to_document_symbol(doc, s))
   end
   logger:debug("Returning %d top-level symbols", #result)
   setmetatable(result, json.empty_array_mt)
   self._lsp_reader_writer:send_rpc(id, result)
end

function NavigationHandlers:_normalize(path)
   return self._server_state:absolute_path(path)
end

function NavigationHandlers:_open_doc(path)
   return self._document_manager:get(Uri.uri_from_path(path))
end

function NavigationHandlers:_load_symbols(path)
   local doc = self:_open_doc(path)
   if doc then
      return doc:get_symbols()
   end
   local fd = io.open(path, "rb")
   if not fd then
      return {}
   end
   local text = fd:read("*a")
   fd:close()
   local tokens = tl.lex(text, path)
   local errs = {}
   local ast = ast_walk.parse_program(tokens, errs, path)
   local ok, result = pcall(symbols.document_symbols, tokens, ast)
   return ok and result or {}
end

function NavigationHandlers:_view(doc)

   doc:get_problems()
   return {
      path = doc.uri.path,
      tokens = doc:get_tokens(),
      ast = doc:get_ast(),
      report = doc:get_type_report(),
      declaration_of = function(name, y, x)
         return doc:symbol_declaration_position(name, y, x)
      end,
      symbols = doc:get_symbols(),
   }
end

function NavigationHandlers:_views_for(target, current)
   if target.kind == "local" or target.kind == "type" then
      return { self:_view(current) }
   end
   local views = {}
   local paths = {}
   for path in pairs(self._document_manager.docs) do
      table.insert(paths, path)
   end
   table.sort(paths)
   for _, path in ipairs(paths) do
      table.insert(views, self:_view(self._document_manager.docs[path]))
   end
   return views
end


function NavigationHandlers:_target(params)
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      return nil, nil
   end
   local pos = handler_helper.byte_position(self._document_manager, params)
   local normalize = function(p) return self:_normalize(p) end
   local target = references.resolve_target(self:_view(doc), normalize, pos.line + 1, pos.character + 1)
   return target, doc
end

function NavigationHandlers:_find(target, doc)
   local normalize = function(p) return self:_normalize(p) end
   local loader = function(p) return self:_load_symbols(p) end
   return references.find(self:_views_for(target, doc), target, normalize, loader)
end

function NavigationHandlers:_lsp_range(file, y, x, yend, xend)
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

function NavigationHandlers:_on_references(params, id)
   local target, doc = self:_target(params)
   local result = {}
   if target then
      local context = (params.context or {})
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
   setmetatable(result, json.empty_array_mt)
   self._lsp_reader_writer:send_rpc(id, result)
end

local highlight_kind = {
   decl = 3,
   write = 3,
   read = 2,
}

function NavigationHandlers:_on_document_highlight(params, id)
   local target, doc = self:_target(params)
   local result = {}
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
   setmetatable(result, json.empty_array_mt)
   self._lsp_reader_writer:send_rpc(id, result)
end



function NavigationHandlers:_rename_plan(params)
   local target, doc = self:_target(params)
   if target == nil then
      return nil, nil, nil, "No renameable symbol at this position"
   end
   if target.kind == "type" then
      return nil, nil, nil, "Renaming types is not supported yet: uses in type annotations are not tracked"
   end
   if target.kind == "field" then
      local owner_file = references.owner_file(target)
      if owner_file and not self:_open_doc(owner_file) then
         return nil, nil, nil, string.format("Cannot rename '%s': it is declared in %s, which is not open", target.name, owner_file)
      end
   end
   local locations, unresolved = self:_find(target, doc)
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
         return nil, nil, nil, string.format("Cannot rename '%s': it is not declared in an open file", target.name)
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
      if not self:_open_doc(loc.file) then
         return nil, nil, nil, string.format("Cannot rename '%s': %s is not open", target.name, loc.file)
      end
   end
   return target, doc, locations, nil
end

function NavigationHandlers:_on_prepare_rename(params, id)
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

function NavigationHandlers:_on_rename(params, id)
   local new_name = params.newName
   if not references.is_valid_name(new_name) then
      self._lsp_reader_writer:send_rpc_error(id, "InvalidParams", string.format("'%s' is not a valid Teal identifier", tostring(new_name)))
      return
   end
   local target, _, locations, err = self:_rename_plan(params)
   if target == nil then
      self._lsp_reader_writer:send_rpc_error(id, "RequestFailed", err)
      return
   end

   local by_file = {}
   local files = {}
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

   local edit
   if self._server_state:client_capability("workspace", "workspaceEdit", "documentChanges") then
      local changes = {}
      for _, file in ipairs(files) do
         local d = self:_open_doc(file)
         table.insert(changes, {
            textDocument = { uri = Uri.tostring(d.uri), version = d.version },
            edits = by_file[file],
         })
      end
      edit = { documentChanges = changes }
   else
      local changes = {}
      for _, file in ipairs(files) do
         changes[Uri.tostring(Uri.uri_from_path(file))] = by_file[file]
      end
      edit = { changes = changes }
   end
   self._lsp_reader_writer:send_rpc(id, edit)

   if target.kind ~= "local" then
      self._lsp_reader_writer:send_rpc_notification("window/showMessage", {
         type = lsp.message_type.Info,
         message = string.format("Renamed '%s' in open files; references in files that are not open were not updated.", target.name),
      })
   end
end

function NavigationHandlers:_on_workspace_symbol(params, id)
   local query = (params.query or "")
   local index = self._server_state:get_workspace_index()
   workspace_index.refresh(index, function(path)
      return self._document_manager:open_content(path)
   end)
   local result = {}
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
   setmetatable(result, json.empty_array_mt)
   self._lsp_reader_writer:send_rpc(id, result)
end

function NavigationHandlers:initialize()
   self._lsp_events_manager:set_handler("textDocument/documentSymbol", function(params, id) self:_on_document_symbol(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/references", function(params, id) self:_on_references(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/documentHighlight", function(params, id) self:_on_document_highlight(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/prepareRename", function(params, id) self:_on_prepare_rename(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/rename", function(params, id) self:_on_rename(params, id) end)
   self._lsp_events_manager:set_handler("workspace/symbol", function(params, id) self:_on_workspace_symbol(params, id) end)
end

class.setup(NavigationHandlers, "NavigationHandlers", {})

return NavigationHandlers
