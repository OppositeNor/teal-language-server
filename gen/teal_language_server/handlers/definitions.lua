local _module_name = "handlers.definitions"

local handler_helper = require("teal_language_server.handlers.handler_helper")
local DocumentManager = require("teal_language_server.analysis.document_manager")
local Document = require("teal_language_server.analysis.document")
local ServerState = require("teal_language_server.server_state")
local LspReaderWriter = require("teal_language_server.lsp.reader_writer")
local LspEventsManager = require("teal_language_server.lsp.events_manager")
local Path = require("teal_language_server.util.path")
local Uri = require("teal_language_server.util.uri")
local position = require("teal_language_server.util.position")
local lsp = require("teal_language_server.lsp.protocol")
local logging = require("teal_language_server.logging")
local class = require("teal_language_server.util.class")

local logger = logging.get_logger(_module_name)






local function tokens_for_node(node_info, self_type)
   if handler_helper.indexable_parent_types[node_info.parent_type] then
      return Document.split_by_symbols(node_info.parent_source, self_type, node_info.source)
   else
      return Document.split_by_symbols(node_info.source, self_type)
   end
end

local DefinitionHandlers = {}








function DefinitionHandlers:__init(lsp_events_manager, lsp_reader_writer, server_state, document_manager)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
   self._document_manager = document_manager
end




function DefinitionHandlers:_send_location(id, doc, file, y, x)
   if file == nil or y == nil or x == nil then
      return false
   end

   local file_uri
   local target_doc

   if #file == 0 or file == doc.uri.path then
      file_uri = doc.uri
      target_doc = doc
   else
      local full_path

      if Path(file):is_absolute() then
         full_path = file
      else
         full_path = self._server_state.teal_project_root_dir.value .. "/" .. file
      end

      file_uri = Uri.uri_from_path(Path(full_path).value)
      target_doc = self._document_manager:get(file_uri)
   end

   local target_pos
   if target_doc then
      target_pos = target_doc:to_lsp_position(y, x)
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






function DefinitionHandlers:_on_definition(params, id)
   local pos = handler_helper.byte_position(self._document_manager, params)
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


   if #tks == 1 then
      local decl_y, decl_x = doc:symbol_declaration_position(tks[1], pos.line, pos.character)
      if decl_y ~= nil and self:_send_location(id, doc, doc.uri.path, decl_y, decl_x) then
         return
      end


   end



   local type_info = doc:type_information_for_tokens(tks, pos.line, pos.character)
   if type_info and self:_send_location(id, doc, type_info.file, type_info.y, type_info.x) then
      logger:trace("[on_definition] Resolved via field/type position")
      return
   end



   if #tks > 1 then
      local parent_tks = {}
      for i = 1, #tks - 1 do parent_tks[i] = tks[i] end
      local parent_info = doc:type_information_for_tokens(parent_tks, pos.line, pos.character)
      if parent_info and self:_send_location(id, doc, parent_info.file, parent_info.y, parent_info.x) then
         logger:trace("[on_definition] Resolved via enclosing record position")
         return
      end
   end

   self._lsp_reader_writer:send_rpc(id, nil)
end




function DefinitionHandlers:_on_type_definition(params, id)
   local pos = handler_helper.byte_position(self._document_manager, params)
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
   self._lsp_events_manager:set_handler("textDocument/definition", function(params, id) self:_on_definition(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/typeDefinition", function(params, id) self:_on_type_definition(params, id) end)
end

class.setup(DefinitionHandlers, "DefinitionHandlers", {})

return DefinitionHandlers
