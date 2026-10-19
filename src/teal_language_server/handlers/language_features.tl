local _module_name = "handlers.language_feature"

local handler_helper <const> = require("teal_language_server.handlers.handler_helper")
local DocumentManager <const> = require("teal_language_server.analysis.document_manager")
local ServerState <const> = require("teal_language_server.server_state")
local workspace_index <const> = require("teal_language_server.analysis.workspace_index")
local position <const> = require("teal_language_server.util.position")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local inlay_hints <const> = require("teal_language_server.analysis.inlay_hints")
local Document <const> = require("teal_language_server.analysis.document")
local LspReaderWriter <const> = require("teal_language_server.lsp.reader_writer")
local LspEventsManager <const> = require("teal_language_server.lsp.events_manager")
local lsp <const> = require("teal_language_server.lsp.protocol")
local logging <const> = require("teal_language_server.logging")
local class <const> = require("teal_language_server.util.class")
local tl <const> = require("tl")
local lsp_formatter <const> = require("teal_language_server.lsp.formatter")
local json <const> = require("cjson")

local logger = logging.get_logger(_module_name)

local record LanguageFeatureHandlers
   _document_manager: DocumentManager
   _server_state: ServerState
   _lsp_reader_writer: LspReaderWriter
   _lsp_events_manager: LspEventsManager

   metamethod __call: function(self: LanguageFeatureHandlers, lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, document_manager: DocumentManager, server_state: ServerState): LanguageFeatureHandlers
end

function LanguageFeatureHandlers:__init(lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, document_manager: DocumentManager, server_state: ServerState)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._document_manager = document_manager
   self._server_state = server_state
end

local TEAL_KEYWORDS <const> = {
   "and", "break", "do", "else", "elseif", "end", "enum", "false", "for", "function",
   "global", "goto", "if", "in", "interface", "local", "nil", "not", "or", "record",
   "repeat", "return", "then", "true", "type", "until", "while",
}

local function is_callable(ti: tl.TypeInfo): boolean
   return ti.t == tl.typecodes.FUNCTION or ti.t == tl.typecodes.POLY
end

-- Snippet escaping for placeholder text
local function snippet_escape(s: string): string
   return (s:gsub("[%$}\\]", "\\%0"))
end

-- Builds a completion item for a field/variable `key` of type `ti`. Functions
-- get their signature as documentation and, when the client supports
-- snippets, an insert text with parameter placeholders (without `self` for
-- method calls through `:`).
function LanguageFeatureHandlers:_completion_item(doc: Document, key: string, ti: tl.TypeInfo, colon_access: boolean): {string:any}
   local item: {string:any} = {
      label = key,
      kind = lsp.typecodes_to_kind[ti.t],
      detail = ti.str,
   }
   if colon_access and is_callable(ti) then
      item.kind = lsp.completion_item_kind.Method
   end
   if ti.t == tl.typecodes.FUNCTION and ti.str then
      local args = doc:get_function_args_string(ti)
      if args then
         item.documentation = {
            kind = "markdown",
            value = "```teal\n" .. lsp_formatter.create_function_string(ti.str, args, key) .. "\n```",
         }
         if self._server_state:client_capability("textDocument", "completion", "completionItem", "snippetSupport") then
            local placeholders: {string} = {}
            for i, name in ipairs(args) do
               if not (i == 1 and colon_access and name == "self") and name ~= "..." then
                  table.insert(placeholders, "${" .. (#placeholders + 1) .. ":" .. snippet_escape(name) .. "}")
               end
            end
            item.insertText = key .. "(" .. table.concat(placeholders, ", ") .. ")"
            item.insertTextFormat = 2
         end
      end
   end
   return item
end

-- Completion of module names inside `require("...")`. Returns true if the
-- cursor is in such a string (and a response was sent).
function LanguageFeatureHandlers:_complete_require(params: lsp.Method.Params, id: integer, pos: lsp.Position): boolean
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      return false
   end
   local line = doc:get_line(pos.line)
   local before = line:sub(1, pos.character)
   local start_col = before:match("require%s*%(?%s*[\"']()[%w_%.%-]*$") as integer
   if start_col == nil then
      return false
   end
   local index = self._server_state:get_workspace_index()
   workspace_index.refresh(index, function(path: string): string
      return self._document_manager:open_content(path)
   end)
   local range: lsp.Range = {
      start = lsp.position(pos.line, position.byte_to_utf16(line, start_col - 1)),
      ["end"] = lsp.position(pos.line, position.byte_to_utf16(line, pos.character)),
   }
   local items: {any} = {}
   for _, name in ipairs(workspace_index.module_names(index)) do
      table.insert(items, {
         label = name,
         kind = lsp.completion_item_kind.Module,
         textEdit = { range = range, newText = name },
      })
   end
   setmetatable(items, json.empty_array_mt as metatable<{any}>)
   self._lsp_reader_writer:send_rpc(id, { isIncomplete = false, items = items })
   return true
end

function LanguageFeatureHandlers:_on_completion(params: lsp.Method.Params, id: integer): nil
   local pos = handler_helper.byte_position(self._document_manager, params)
   logger:info("Received request for completion at position: %s", pos)

   if self:_complete_require(params, id, pos) then
      return
   end

   -- Subtract one since neovim passes the character where the cursor is, which is after the '.' / ':'
   -- and this position doesn't exist in the doc so can lead to tree sitter query fails
   pos.character = pos.character - 1

   local node_info, doc = handler_helper.get_node_info(self._document_manager, params, pos)
   if node_info == nil then
      logger:trace("No node found at given position")
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   logger:debug("Found node info: %s", node_info)

   local type_info: tl.TypeInfo
   local scope_completion = false

   -- literally at the . or : and are trying to autocomplete
   -- preceded_by should have everything we need in it.
   if node_info.type == "." or node_info.type == ":" then
      type_info = doc:resolve_preceded_type(node_info, pos)

   -- completion request in the middle of a word like in "node_info.par" while typing "parent_source"
   elseif node_info.type == "identifier" then
      local tks: {string}
      -- the types that we would need to index into to get type info from
      if handler_helper.indexable_parent_types[node_info.parent_type] then
         tks = Document.split_by_symbols(node_info.parent_source, node_info.self_type)
      else
         tks = Document.split_by_symbols(node_info.source, node_info.self_type)
      end

      -- takes it back to the just after the first dot, then does completion
      -- if there's only one symbol, will return an empty list and type_information_for_tokens will just
      -- show what's in scope
      tks[#tks] = nil

      -- trying to define something new, probably don't want the in-scope thing to popup
      -- we could probably help complete simple types
      if node_info.parent_type == "var" or
         node_info.parent_type == "simple_type" or
         node_info.parent_type == "table_type" then
         self._lsp_reader_writer:send_rpc(id, nil)
         return
      end

      type_info = doc:type_information_for_tokens(tks, pos.line, pos.character)
      -- completing a bare identifier: also offer keywords
      scope_completion = #tks == 0
   else
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local items:{any} = { }

   if not type_info then
      logger:info("Also failed to find type type_info based on token")
   end

   if type_info then
      logger:debug("Successfully found type_info")
      local tr = doc:get_type_report()

      if type_info.ref then
         type_info = doc:resolve_type_ref(type_info.ref)
      end

      -- string
      local was_string_type = type_info.t == tl.typecodes.STRING
      if was_string_type then
         type_info = tr.types[tr.globals["string"]]
      end

      -- this seemed to be the best way to compare the first arg with itself when comparing ":",
      -- sometimes the types come in as nominal and don't resolve all the way back, so the name is
      -- what seems to work the most reliably
      local original_str = type_info.str

      -- true if fn is a single-signature function whose first arg is the receiver,
      -- i.e. it can be called with ':' on this type
      local function is_self_method(fn: tl.TypeInfo): boolean
         if fn.t ~= tl.typecodes.FUNCTION or not fn.args or #fn.args < 1 then
            return false
         end
         local first_arg_type = doc:resolve_type_ref(fn.args[1][1])
         return first_arg_type.t == tl.typecodes.SELF
            or ((first_arg_type.t == tl.typecodes.NOMINAL or first_arg_type.t == tl.typecodes.RECORD) and first_arg_type.str == original_str)
            or (was_string_type and first_arg_type.t == tl.typecodes.STRING)
      end

      if type_info.fields then
         for key, v in pairs(type_info.fields) do
            type_info = doc:resolve_type_ref(v)
            local was_added:boolean
            -- self based access should only show functions
            if node_info.type == ":" then
               -- overloaded methods (e.g. FILE:read) arrive as POLY, so check each
               -- overload and keep the method if any is a self-callable function
               local self_method = false
               if type_info.t == tl.typecodes.POLY then
                  for _, ref in ipairs(type_info.types) do
                     if is_self_method(doc:resolve_type_ref(ref)) then
                        self_method = true
                        break
                     end
                  end
               else
                  self_method = is_self_method(type_info)
               end

               if self_method then
                  logger:debug("Adding self method %s", key)
                  table.insert(items, self:_completion_item(doc, key, type_info, true))
                  was_added = true
               else
                  logger:debug("Ignoring method %s with type 0x%08x for type info str %s",
                     key, type_info.t, original_str)
               end
            else
               table.insert(items, self:_completion_item(doc, key, type_info, false))
               was_added = true
            end

            if not was_added then
               logger:trace("Ignoring field %s", key)
            end
         end

      -- at a table, we might be able to help resolve the keys!
      elseif type_info.keys then
         type_info = doc:resolve_type_ref(type_info.keys)

         if type_info.enums then
            for _, enum_value in ipairs(type_info.enums) do
               table.insert(items, {label = enum_value, kind = lsp.typecodes_to_kind[type_info.t]})
            end
         end
      else
         logger:info("Unable to get fields for ref type")
      end
   end

   if scope_completion then
      for _, kw in ipairs(TEAL_KEYWORDS) do
         table.insert(items, { label = kw, kind = lsp.completion_item_kind.Keyword })
      end
   end

   setmetatable(items, json.empty_array_mt as metatable<{any}>)

   logger:debug("Sending %d back to client", #items)

   self._lsp_reader_writer:send_rpc(id, {
      isIncomplete = false,
      items = items
   })
end

-- Finds the call whose argument list contains the cursor: scans the lexer
-- tokens backwards from the cursor to the innermost unmatched "(" that follows
-- a callable expression. Returns that "(" token, the number of top-level
-- commas between it and the cursor (the active argument), and whether the
-- call is a method call through ":".
local function enclosing_call(tokens: {tl.Token}, y: integer, x: integer): tl.Token, integer, boolean
   -- last token starting before the cursor
   local idx = ast_walk.token_index_at(tokens, y, x - 1)
   local depth = 0
   local commas = 0
   local scanned = 0
   while idx >= 1 and scanned < 5000 do
      local t = tokens[idx]
      local tk = t.tk
      if tk == ")" or tk == "}" or tk == "]" then
         depth = depth + 1
      elseif tk == "{" or tk == "[" then
         if depth == 0 then
            -- the cursor is inside a table constructor (or index) that is itself
            -- an argument: its commas are not argument separators
            commas = 0
         else
            depth = depth - 1
         end
      elseif tk == "(" then
         if depth == 0 then
            local prev = tokens[idx - 1]
            local before_prev = tokens[idx - 2]
            local callable = prev ~= nil and (prev.kind == "identifier" or prev.tk == ")" or prev.tk == "]" or prev.tk == "self")
            -- `function name(` is a definition, not a call
            if callable and before_prev and before_prev.tk == "function" then
               return nil, 0, false
            end
            if callable then
               local method = before_prev ~= nil and before_prev.tk == ":"
               return t, commas, method
            end
            return nil, 0, false
         end
         depth = depth - 1
      elseif tk == "," and depth == 0 then
         commas = commas + 1
      elseif depth == 0 and (tk == "local" or tk == "function" or tk == "end" or tk == "then" or tk == "do" or tk == "return") then
         return nil, 0, false
      end
      idx = idx - 1
      scanned = scanned + 1
   end
   return nil, 0, false
end

-- Byte ranges [start, end) of the top-level parameters in a signature label
-- such as "name<T>(a: T, b: {string:T}): T".
local function label_parameter_ranges(label: string): {{integer, integer}}
   local ranges: {{integer, integer}} = {}
   local open: integer
   local angle = 0
   for i = 1, #label do
      local c = label:sub(i, i)
      if c == "<" then angle = angle + 1
      elseif c == ">" then angle = angle - 1
      elseif c == "(" and angle == 0 then
         open = i
         break
      end
   end
   if open == nil then
      return ranges
   end
   local depth = 0
   local start = open + 1
   for i = open + 1, #label do
      local c = label:sub(i, i)
      if c == "(" or c == "{" or c == "<" then
         depth = depth + 1
      elseif c == ")" or c == "}" or c == ">" then
         if depth == 0 then
            if i > start then
               table.insert(ranges, { start, i })
            end
            break
         end
         depth = depth - 1
      elseif c == "," and depth == 0 then
         table.insert(ranges, { start, i })
         start = i + 1
      end
   end
   -- trim surrounding spaces
   for _, r in ipairs(ranges) do
      while label:sub(r[1], r[1]) == " " and r[1] < r[2] do r[1] = r[1] + 1 end
      while label:sub(r[2] - 1, r[2] - 1) == " " and r[2] > r[1] do r[2] = r[2] - 1 end
   end
   return ranges
end

function LanguageFeatureHandlers:_on_signature_help(params: lsp.Method.Params, id: integer): nil
   local pos = handler_helper.byte_position(self._document_manager, params)
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   -- locate the call around the cursor; fall back to "cursor right after (" for
   -- code the lexer cannot make sense of
   local paren, active_arg, method_call = enclosing_call(doc:get_tokens(), pos.line + 1, pos.character + 1)
   local lookup: lsp.Position
   if paren then
      lookup = lsp.position(paren.y - 1, paren.x - 1)
   else
      lookup = lsp.position(pos.line, pos.character - 1)
      active_arg = 0
   end

   local node_info = handler_helper.get_node_info(self._document_manager, params, lookup)
   if node_info == nil or node_info.type ~= "(" then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   logger:debug("Got nodeinfo: %s", node_info)
   local type_info = doc:resolve_preceded_type(node_info, lookup)
   if type_info == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local candidates: {tl.TypeInfo} = {}
   if type_info.t == tl.typecodes.POLY then
      for _, type_ref in ipairs(type_info.types) do
         table.insert(candidates, doc:resolve_type_ref(type_ref))
      end
   else
      table.insert(candidates, type_info)
   end

   local output: lsp_formatter.SignatureHelp = { signatures = {}, activeSignature = 0, activeParameter = 0 }
   for _, candidate in ipairs(candidates) do
      if candidate and candidate.str then
         local args = doc:get_function_args_string(candidate)
         local label: string
         if args ~= nil then
            label = lsp_formatter.create_function_string(candidate.str, args, node_info.preceded_by)
         else
            label = candidate.str
         end
         local parameters: {lsp_formatter.SignatureHelp.SignatureParameter} = {}
         for _, r in ipairs(label_parameter_ranges(label)) do
            table.insert(parameters, {
               label = { position.byte_to_utf16(label, r[1] - 1), position.byte_to_utf16(label, r[2] - 1) },
            })
         end
         -- a method called through ":" passes self implicitly
         local active = active_arg
         if method_call and args and args[1] == "self" then
            active = active + 1
         end
         table.insert(output.signatures, {
            label = label,
            parameters = setmetatable(parameters, json.empty_array_mt as metatable<{lsp_formatter.SignatureHelp.SignatureParameter}>),
            activeParameter = active,
         })
      end
   end

   if #output.signatures == 0 then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end
   output.activeParameter = output.signatures[1].activeParameter
   self._lsp_reader_writer:send_rpc(id, output as {string:any})
end

function LanguageFeatureHandlers:_on_hover(params: lsp.Method.Params, id: integer): nil
   local pos <const> = handler_helper.byte_position(self._document_manager, params)
   logger:trace("Received request for hover at position: %s", pos)
   local node_info, doc = handler_helper.get_node_info(self._document_manager, params, pos)
   if node_info == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local node_range: lsp.Range = {
      start = doc:byte_to_lsp_position(node_info.start_line, node_info.start_col),
      ["end"] = doc:byte_to_lsp_position(node_info.end_line, node_info.end_col),
   }

   local tks: {string} = {}
   local quick_type_info: tl.TypeInfo
   if node_info.type == "identifier" then
      -- resolve directly from by_pos at the identifier's position (works for
      -- locals/globals and, via the field-identifier store, for field access)
      if node_info.bypos_y then
         quick_type_info = doc:type_information_for_position(node_info.bypos_y, node_info.bypos_x)
      end
      -- only build the token-chain fallback when the by_pos lookup missed
      if quick_type_info == nil then
         -- parent types that show up with multiparts
         if handler_helper.indexable_parent_types[node_info.parent_type] then
            tks = Document.split_by_symbols(node_info.parent_source, node_info.self_type, node_info.source)
         else
            tks = Document.split_by_symbols(node_info.source, node_info.self_type)
         end
      end
   else
      logger:warning("Can't hover over anything that isn't an identifier atm: %s", node_info.type)
      self._lsp_reader_writer:send_rpc(id, {
         contents = { node_info.parent_type, ":", node_info.type },
         range = node_range,
      })
      return
   end

   local type_info = quick_type_info or doc:type_information_for_tokens(tks, pos.line, pos.character)

   if not type_info then
      logger:warning("Also failed to find type info based on token")
      self._lsp_reader_writer:send_rpc(id, {
         contents = { node_info.source .. ":", " No type_info found " },
         range = node_range,
      })
      return
   end

   logger:debug("Successfully found type_info: %s", type_info)

   local type_str <const> = lsp_formatter.show_type(node_info, type_info, doc)
   self._lsp_reader_writer:send_rpc(id, {
      contents = type_str,
      range = node_range,
   })
end

function LanguageFeatureHandlers:_inlay_hints_enabled(): boolean
   local externals = (self._server_state.config or {}).externals
   local ours = externals and (externals as {string:any}).teal_language_server
   return not (type(ours) == "table" and (ours as {string:any}).inlay_hints == false)
end

function LanguageFeatureHandlers:_on_inlay_hint(params: lsp.Method.Params, id: integer): nil
   local doc = handler_helper.get_document(self._document_manager, params)
   local result: {{string:any}} = {}
   if doc and self:_inlay_hints_enabled() then
      local range = params.range as lsp.Range
      local first_line = range and range.start.line + 1 or 1
      local last_line = range and range["end"].line + 1 or math.maxinteger
      local report = doc:get_type_report()
      local by_pos = report.by_pos[doc.uri.path]
      local function type_str_at(y: integer, x: integer): string
         local row = by_pos and by_pos[y]
         local type_id = row and row[x]
         local ti = type_id and report.types[type_id]
         return ti and ti.str
      end
      local ast = doc:get_ast()
      for _, h in ipairs(inlay_hints.compute(doc:get_tokens(), ast as ast_walk.AstNode, type_str_at, first_line, last_line)) do
         table.insert(result, {
            position = doc:to_lsp_position(h.y, h.x),
            label = h.label,
            kind = 1, -- InlayHintKind.Type
         })
      end
   end
   setmetatable(result, json.empty_array_mt as metatable<{{string:any}}>)
   self._lsp_reader_writer:send_rpc(id, result as {string:any})
end

function LanguageFeatureHandlers:initialize()
   self._lsp_events_manager:set_handler("textDocument/completion", function(params: lsp.Method.Params, id: integer) self:_on_completion(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/signatureHelp", function(params: lsp.Method.Params, id: integer) self:_on_signature_help(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/hover", function(params: lsp.Method.Params, id: integer) self:_on_hover(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/inlayHint", function(params: lsp.Method.Params, id: integer) self:_on_inlay_hint(params, id) end)
end

class.setup(LanguageFeatureHandlers, "LanguageFeatureHandlers", {})

return LanguageFeatureHandlers
