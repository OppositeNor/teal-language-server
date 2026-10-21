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
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local lsp <const> = require("teal_language_server.lsp.protocol")
local logging <const> = require("teal_language_server.logging")
local class <const> = require("teal_language_server.util.class")
local references <const> = require("teal_language_server.analysis.references")
local symbols <const> = require("teal_language_server.analysis.symbols")
local NavigationHandlers <const> = require("teal_language_server.handlers.navigation")
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
   -- workspace search, for jumping from a declaration to its implementation
   _navigation: NavigationHandlers
   _server_state: ServerState
   _lsp_reader_writer: LspReaderWriter
   _lsp_events_manager: LspEventsManager

   metamethod __call: function(self: DefinitionHandlers, lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, server_state: ServerState, document_manager: DocumentManager, navigation?: NavigationHandlers): DefinitionHandlers
end

function DefinitionHandlers:__init(lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, server_state: ServerState, document_manager: DocumentManager, navigation?: NavigationHandlers)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
   self._document_manager = document_manager
   self._navigation = navigation
end

local TYPE_KEYWORDS <const>: {string:boolean} = {
   ["record"] = true,
   ["enum"] = true,
   ["interface"] = true,
}

-- tl records nested type declarations at their keyword (`record Name`); point
-- at the name instead, like top-level declarations.
local function past_type_keyword(tokens: {tl.Token}, y: integer, x: integer): integer, integer
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

local function read_file(path: string): string
   local fd = io.open(path, "rb")
   if not fd then
      return nil
   end
   local text = fd:read("*a")
   fd:close()
   return text
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
      y, x = past_type_keyword(target_doc:get_tokens(), y, x)
      target_pos = target_doc:to_lsp_position(y, x)
   elseif lfs.attributes(file_uri.path, "mode") ~= "file" then
      -- e.g. tl's built-in declarations ("stdlib.d.tl"), which are not a file
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

local TYPE_SYMBOL_KINDS <const>: {string:boolean} = {
   Class = true,
   Interface = true,
   Enum = true,
   TypeParameter = true,
}

local function contains(s: symbols.Symbol, y: integer, x: integer): boolean
   return (s.y < y or (s.y == y and s.x <= x)) and (y < s.yend or (y == s.yend and x < s.xend))
end

local function child_type(s: symbols.Symbol, name: string): symbols.Symbol
   for _, c in ipairs(s.children or {}) do
      if c.name == name and TYPE_SYMBOL_KINDS[c.kind] then
         return c
      end
   end
   return nil
end

-- Resolves a (possibly qualified) type name used inside record bodies, e.g.
-- `p_params: RTParams` in a field's function type where RTParams is a sibling
-- nested type. Such names are visible through the enclosing records rather
-- than as variables in scope, so neither the compiler's scope list nor the
-- type report resolves them. Searches the records enclosing (y, x), innermost
-- first (the record itself, then its nested types), then the file's
-- top-level types, and follows the remaining qualified parts.
local function outline_type_declaration(outline: {symbols.Symbol}, tks: {string}, y: integer, x: integer): symbols.Symbol
   if #tks == 0 then
      return nil
   end
   local chain: {symbols.Symbol} = {}
   local level = outline
   while level do
      local inner: symbols.Symbol
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

   local found: symbols.Symbol
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

-- Sends the location of a type name resolved through the outline (see
-- outline_type_declaration); returns false if it does not resolve.
function DefinitionHandlers:_send_outline_type_location(id: integer, doc: Document, tks: {string}, pos: lsp.Position): boolean
   local decl = outline_type_declaration(doc:get_symbols(), tks, pos.line + 1, pos.character + 1)
   if decl == nil then
      return false
   end
   return self:_send_location(id, doc, doc.uri.path, decl.sel_y, decl.sel_x)
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
      -- on a field's declaration, go to its implementation(s)
      local impls = self._navigation and self._navigation:implementations_from_declaration(current, pos)
      if impls then
         if #impls == 1 then
            self._lsp_reader_writer:send_rpc(id, impls[1])
         else
            self._lsp_reader_writer:send_rpc(id, impls as {string:any})
         end
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

   -- A type name used inside a record body (e.g. in a field's function type)
   if self:_send_outline_type_location(id, doc, tks, pos) then
      logger:trace("[on_definition] Resolved via the enclosing records' nested types")
      return
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

   if type_info and self:_send_location(id, doc, type_info.file, type_info.y, type_info.x) then
      return
   end
   if self:_send_outline_type_location(id, doc, tks, pos) then
      return
   end
   self._lsp_reader_writer:send_rpc(id, nil)
end

function DefinitionHandlers:initialize()
   self._lsp_events_manager:set_handler("textDocument/definition", function(params: lsp.Method.Params, id: integer) self:_on_definition(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/typeDefinition", function(params: lsp.Method.Params, id: integer) self:_on_type_definition(params, id) end)
end

class.setup(DefinitionHandlers, "DefinitionHandlers", {})

return DefinitionHandlers
