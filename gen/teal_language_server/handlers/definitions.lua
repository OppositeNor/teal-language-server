local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local table = _tl_compat and _tl_compat.table or table; local _module_name = "handlers.definitions"

local handler_helper = require("teal_language_server.handlers.handler_helper")
local DocumentManager = require("teal_language_server.analysis.document_manager")
local Document = require("teal_language_server.analysis.document")
local ServerState = require("teal_language_server.server_state")
local LspReaderWriter = require("teal_language_server.lsp.reader_writer")
local LspEventsManager = require("teal_language_server.lsp.events_manager")
local Path = require("teal_language_server.util.path")
local Uri = require("teal_language_server.util.uri")
local position = require("teal_language_server.util.position")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local lsp = require("teal_language_server.lsp.protocol")
local logging = require("teal_language_server.logging")
local class = require("teal_language_server.util.class")
local references = require("teal_language_server.analysis.references")
local symbols = require("teal_language_server.analysis.symbols")
local NavigationHandlers = require("teal_language_server.handlers.navigation")
local semantic = require("teal_language_server.analysis.semantic")
local tl = require("tl")
local lfs = require("lfs")

local logger = logging.get_logger(_module_name)






local function tokens_for_node(node_info, self_type)
   if handler_helper.indexable_parent_types[node_info.parent_type] then
      return Document.split_by_symbols(node_info.parent_source, self_type, node_info.source)
   else
      return Document.split_by_symbols(node_info.source, self_type)
   end
end

local DefinitionHandlers = {}










function DefinitionHandlers:__init(lsp_events_manager, lsp_reader_writer, server_state, document_manager, navigation)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
   self._document_manager = document_manager
   self._navigation = navigation
end

local TYPE_KEYWORDS = {
   ["record"] = true,
   ["enum"] = true,
   ["interface"] = true,
}



local function past_type_keyword(tokens, y, x)
   if tokens == nil then
      return y, x
   end
   local tok = ast_walk.token_at(tokens, y, x)
   if tok and TYPE_KEYWORDS[tok.tk] then
      local nxt = tokens[ast_walk.token_index_at(tokens, y, x) + 1]
      if nxt and nxt.kind == "identifier" then
         return nxt.y, nxt.x
      end
   end
   return y, x
end

local function read_file(path)
   local fd = io.open(path, "rb")
   if not fd then
      return nil
   end
   local text = fd:read("*a")
   fd:close()
   return text
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
      y, x = past_type_keyword(target_doc:get_tokens(), y, x)
      target_pos = target_doc:to_lsp_position(y, x)
   elseif lfs.attributes(file_uri.path, "mode") ~= "file" then

      return false
   else
      local text = read_file(file_uri.path)
      if text then
         y, x = past_type_keyword(tl.lex(text, file_uri.path), y, x)
      end
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










function DefinitionHandlers:_semantic_definition(doc, pos)
   local normalize = function(p) return self._server_state:absolute_path(p) end
   local loader = function(p) return handler_helper.load_symbols(self._document_manager, p) end
   local ok, target = pcall(references.resolve_target, handler_helper.view(doc), normalize, pos.line + 1, pos.character + 1)
   if not ok or target == nil then
      return nil
   end
   local out = {}
   for _, loc in ipairs(references.declarations(target, loader)) do
      local file = loc.file == "" and doc.uri.path or normalize(loc.file)
      local uri = Uri.uri_from_path(Path(file).value)
      local target_doc = self._document_manager:get(uri)
      local range
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



function DefinitionHandlers:_required_module_location(doc, pos)
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

local TYPE_SYMBOL_KINDS = {
   Class = true,
   Interface = true,
   Enum = true,
   TypeParameter = true,
}

local function contains(s, y, x)
   return (s.y < y or (s.y == y and s.x <= x)) and (y < s.yend or (y == s.yend and x < s.xend))
end

local function child_type(s, name)
   for _, c in ipairs(s.children or {}) do
      if c.name == name and TYPE_SYMBOL_KINDS[c.kind] then
         return c
      end
   end
   return nil
end








local function outline_type_declaration(outline, tks, y, x)
   if #tks == 0 then
      return nil
   end
   local chain = {}
   local level = outline
   while level do
      local inner
      for _, s in ipairs(level) do
         if TYPE_SYMBOL_KINDS[s.kind] and contains(s, y, x) then
            inner = s
            break
         end
      end
      if inner == nil then
         break
      end
      table.insert(chain, inner)
      level = inner.children
   end

   local found
   for i = #chain, 1, -1 do
      local scope = chain[i]
      if scope.name == tks[1] then
         found = scope
      else
         found = child_type(scope, tks[1])
      end
      if found then break end
   end
   if found == nil then
      for _, s in ipairs(outline) do
         if s.name == tks[1] and TYPE_SYMBOL_KINDS[s.kind] then
            found = s
            break
         end
      end
   end
   for i = 2, #tks do
      if found == nil then
         return nil
      end
      found = child_type(found, tks[i])
   end
   return found
end



function DefinitionHandlers:_send_outline_type_location(id, doc, tks, pos)
   local decl = outline_type_declaration(doc:get_symbols(), tks, pos.line + 1, pos.character + 1)
   if decl == nil then
      return false
   end
   return self:_send_location(id, doc, doc.uri.path, decl.sel_y, decl.sel_x)
end

function DefinitionHandlers:_on_definition(params, id)
   local pos = handler_helper.byte_position(self._document_manager, params)
   local current = handler_helper.get_document(self._document_manager, params)
   if current then
      local module_location = self:_required_module_location(current, pos)
      if module_location then
         self._lsp_reader_writer:send_rpc(id, module_location)
         return
      end

      local impls = self._navigation and self._navigation:implementations_from_declaration(current, pos)
      if impls then
         if #impls == 1 then
            self._lsp_reader_writer:send_rpc(id, impls[1])
         else
            self._lsp_reader_writer:send_rpc(id, impls)
         end
         return
      end
      local locations = self:_semantic_definition(current, pos)
      if locations then

         if #locations == 1 then
            self._lsp_reader_writer:send_rpc(id, locations[1])
         else
            self._lsp_reader_writer:send_rpc(id, locations)
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


   if self:_send_outline_type_location(id, doc, tks, pos) then
      logger:trace("[on_definition] Resolved via the enclosing records' nested types")
      return
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

   if type_info and self:_send_location(id, doc, type_info.file, type_info.y, type_info.x) then
      return
   end
   if self:_send_outline_type_location(id, doc, tks, pos) then
      return
   end
   self._lsp_reader_writer:send_rpc(id, nil)
end

function DefinitionHandlers:initialize()
   self._lsp_events_manager:set_handler("textDocument/definition", function(params, id) self:_on_definition(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/typeDefinition", function(params, id) self:_on_type_definition(params, id) end)
end

class.setup(DefinitionHandlers, "DefinitionHandlers", {})

return DefinitionHandlers
