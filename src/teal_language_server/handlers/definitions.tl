local _module_name = "handlers.definitions"

local handler_helper <const> = require("teal_language_server.handlers.handler_helper")
local DocumentManager <const> = require("teal_language_server.analysis.document_manager")
local Document <const> = require("teal_language_server.analysis.document")
local ServerState <const> = require("teal_language_server.server_state")
local LspReaderWriter <const> = require("teal_language_server.lsp.reader_writer")
local LspEventsManager <const> = require("teal_language_server.lsp.events_manager")
local Path <const> = require("teal_language_server.util.path")
local Uri <const> = require("teal_language_server.util.uri")
local position <const> = require("teal_language_server.util.position")
local lsp <const> = require("teal_language_server.lsp.protocol")
local logging <const> = require("teal_language_server.logging")
local class <const> = require("teal_language_server.util.class")
local references <const> = require("teal_language_server.analysis.references")
local symbols <const> = require("teal_language_server.analysis.symbols")
local semantic <const> = require("teal_language_server.analysis.semantic")
local tl <const> = require("tl")
local lfs <const> = require("lfs")

local logger = logging.get_logger(_module_name)

-- Builds the token chain for a node under the cursor. For definition lookups we
-- keep `self` literal (passing "self" as the self_type makes the substitution in
-- split_by_symbols a no-op) so it resolves as a real in-scope parameter symbol
-- rather than relying on the tree-sitter self_type detection, which is only set
-- for named methods and not for function literals.
local function tokens_for_node(node_info: Document.NodeInfo, self_type: string): {string}
   if handler_helper.indexable_parent_types[node_info.parent_type] then
      return Document.split_by_symbols(node_info.parent_source, self_type, node_info.source)
   else
      return Document.split_by_symbols(node_info.source, self_type)
   end
end

local record DefinitionHandlers
   _document_manager: DocumentManager
   _server_state: ServerState
   _lsp_reader_writer: LspReaderWriter
   _lsp_events_manager: LspEventsManager

   metamethod __call: function(self: DefinitionHandlers, lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, server_state: ServerState, document_manager: DocumentManager): DefinitionHandlers
end

function DefinitionHandlers:__init(lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, server_state: ServerState, document_manager: DocumentManager)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
   self._document_manager = document_manager
end

-- Resolves a (possibly relative) source file path to a Uri and replies to `id`
-- with an LSP Location pointing at the 1-indexed (y, x). Returns true if a
-- location was sent, false if `file` was nil (no location available).
function DefinitionHandlers:_send_location(id: integer, doc: Document, file: string, y: integer, x: integer): boolean
   if file == nil or y == nil or x == nil then
      return false
   end

   local file_uri: Uri
   local target_doc: Document

   if #file == 0 or file == doc.uri.path then
      file_uri = doc.uri
      target_doc = doc
   else
      local full_path: string

      if Path(file):is_absolute() then
         full_path = file
      else
         full_path = self._server_state.teal_project_root_dir.value .. "/" .. file
      end

      file_uri = Uri.uri_from_path(Path(full_path).value)
      target_doc = self._document_manager:get(file_uri)
   end

   local target_pos: lsp.Position
   if target_doc then
      target_pos = target_doc:to_lsp_position(y, x)
   elseif lfs.attributes(file_uri.path, "mode") ~= "file" then
      -- e.g. tl's built-in declarations ("stdlib.d.tl"), which are not a file
      return false
   else
      local line_text = position.read_file_line(file_uri.path, y - 1)
      target_pos = lsp.position(y - 1, position.byte_to_utf16(line_text, x - 1))
   end

   self._lsp_reader_writer:send_rpc(id, {
      uri = Uri.tostring(file_uri),
      range = {
         start = target_pos,
         ["end"] = target_pos,
      },
   })
   return true
end

-- "Go to definition": jump to where the *symbol* under the cursor is declared.
-- For a base symbol this is its declaration site; for a field access it is where
-- that field's type is declared (which works across files for record/function
-- fields), falling back to the enclosing record's declaration when the field's
-- type has no position (e.g. primitives like boolean).
-- Declarations of the symbol under the cursor, from the same resolver that
-- references and rename use, so that definition is always one of the
-- declarations references report. Returns nil when the resolver has no
-- declaration for it (globals, names it does not track).
function DefinitionHandlers:_semantic_definition(doc: Document, pos: lsp.Position): {{string:any}}
   local normalize = function(p: string): string return self._server_state:absolute_path(p) end
   local loader = function(p: string): {symbols.Symbol} return handler_helper.load_symbols(self._document_manager, p) end
   local ok, target = pcall(references.resolve_target, handler_helper.view(doc), normalize, pos.line + 1, pos.character + 1)
   if not ok or target == nil then
      return nil
   end
   local out: {{string:any}} = {}
   for _, loc in ipairs(references.declarations(target as references.Target, loader)) do
      local file = loc.file == "" and doc.uri.path or normalize(loc.file)
      local uri = Uri.uri_from_path(Path(file).value)
      local target_doc = self._document_manager:get(uri)
      local range: lsp.Range
      if target_doc then
         range = target_doc:to_lsp_range(loc.y, loc.x, loc.yend, loc.xend)
      else
         local line_text = position.read_file_line(uri.path, loc.y - 1)
         range = {
            start = lsp.position(loc.y - 1, position.byte_to_utf16(line_text, loc.x - 1)),
            ["end"] = lsp.position(loc.yend - 1, position.byte_to_utf16(line_text, loc.xend - 1)),
         }
      end
      table.insert(out, { uri = Uri.tostring(uri), range = range })
   end
   if #out == 0 then
      return nil
   end
   return out
end

-- The file a `require("name")` under the cursor loads, found by tl's own
-- module search (package.path from tlconfig.lua, open buffers first), or nil.
function DefinitionHandlers:_required_module_location(doc: Document, pos: lsp.Position): {string:any}
   local name = semantic.required_module_at(doc:get_tokens(), pos.line + 1, pos.character + 1)
   if name == nil then
      return nil
   end
   local found, fd = tl.search_module(name, true)
   if fd then
      fd:close()
   end
   if found == nil then
      return nil
   end
   local path = self._server_state:absolute_path(found)
   local start = lsp.position(0, 0)
   return { uri = Uri.tostring(Uri.uri_from_path(Path(path).value)), range = { start = start, ["end"] = start } }
end

function DefinitionHandlers:_on_definition(params: lsp.Method.Params, id: integer): nil
   local pos <const> = handler_helper.byte_position(self._document_manager, params)
   local current = handler_helper.get_document(self._document_manager, params)
   if current then
      local module_location = self:_required_module_location(current, pos)
      if module_location then
         self._lsp_reader_writer:send_rpc(id, module_location)
         return
      end
      local locations = self:_semantic_definition(current, pos)
      if locations then
         -- a single declaration as a Location, several as Location[]
         if #locations == 1 then
            self._lsp_reader_writer:send_rpc(id, locations[1])
         else
            self._lsp_reader_writer:send_rpc(id, locations as {string:any})
         end
         return
      end
   end
   local node_info, doc = handler_helper.get_node_info(self._document_manager, params, pos)
   if node_info == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   logger:trace("Received request for on_definition at position: %s", pos)

   if node_info.type ~= "identifier" then
      logger:warning("Can't go to definition of anything that isn't an identifier atm: %s", node_info.type)
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local tks = tokens_for_node(node_info, "self")

   -- Base symbol (e.g. `apple`, `self`, `TestType_mt`): go to its declaration.
   if #tks == 1 then
      local decl_y, decl_x = doc:symbol_declaration_position(tks[1], pos.line, pos.character)
      if decl_y ~= nil and self:_send_location(id, doc, doc.uri.path, decl_y, decl_x) then
         return
      end
      -- Not a tracked symbol (e.g. a global or a type name used as a value):
      -- fall back to where its type is declared so we don't regress those.
   end

   -- Field access (e.g. `self.test_value`, `mod.func`): the field's type carries
   -- the declaration position for record/function fields.
   local type_info = doc:type_information_for_tokens(tks, pos.line, pos.character)
   if type_info and self:_send_location(id, doc, type_info.file, type_info.y, type_info.x) then
      logger:trace("[on_definition] Resolved via field/type position")
      return
   end

   -- The field's type has no position (e.g. a primitive). Fall back to the
   -- enclosing record's declaration.
   if #tks > 1 then
      local parent_tks: {string} = {}
      for i = 1, #tks - 1 do parent_tks[i] = tks[i] end
      local parent_info = doc:type_information_for_tokens(parent_tks, pos.line, pos.character)
      if parent_info and self:_send_location(id, doc, parent_info.file, parent_info.y, parent_info.x) then
         logger:trace("[on_definition] Resolved via enclosing record position")
         return
      end
   end

   self._lsp_reader_writer:send_rpc(id, nil)
end

-- "Go to type definition": jump to where the *type* of the symbol under the
-- cursor is declared. This is the behavior `textDocument/definition` previously
-- had.
function DefinitionHandlers:_on_type_definition(params: lsp.Method.Params, id: integer): nil
   local pos <const> = handler_helper.byte_position(self._document_manager, params)
   local node_info, doc = handler_helper.get_node_info(self._document_manager, params, pos)
   if node_info == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   logger:trace("Received request for on_type_definition at position: %s", pos)

   if node_info.type ~= "identifier" then
      logger:warning("Can't go to type definition of anything that isn't an identifier atm: %s", node_info.type)
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local tks = tokens_for_node(node_info, "self")
   local type_info = doc:type_information_for_tokens(tks, pos.line, pos.character)

   logger:trace("[on_type_definition] Found type type_info: %s", type_info)

   if not type_info or not self:_send_location(id, doc, type_info.file, type_info.y, type_info.x) then
      self._lsp_reader_writer:send_rpc(id, nil)
   end
end

function DefinitionHandlers:initialize()
   self._lsp_events_manager:set_handler("textDocument/definition", function(params: lsp.Method.Params, id: integer) self:_on_definition(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/typeDefinition", function(params: lsp.Method.Params, id: integer) self:_on_type_definition(params, id) end)
end

class.setup(DefinitionHandlers, "DefinitionHandlers", {})

return DefinitionHandlers
