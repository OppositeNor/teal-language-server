local _module_name = "handlers.language_feature"

local handler_helper <const> = require("teal_language_server.handlers.handler_helper")
local DocumentManager <const> = require("teal_language_server.analysis.document_manager")
local ServerState <const> = require("teal_language_server.server_state")
local workspace_index <const> = require("teal_language_server.analysis.workspace_index")
local position <const> = require("teal_language_server.util.position")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local inlay_hints <const> = require("teal_language_server.analysis.inlay_hints")
local completion <const> = require("teal_language_server.analysis.completion")
local semantic <const> = require("teal_language_server.analysis.semantic")
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
-- method calls through `:`). No parentheses are inserted when the text after
-- the cursor already opens a call.
function LanguageFeatureHandlers:_completion_item(doc: Document, key: string, ti: tl.TypeInfo, colon_access: boolean, followed_by_call?: boolean): {string:any}
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
         if not followed_by_call and self._server_state:client_capability("textDocument", "completion", "completionItem", "snippetSupport") then
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

local candidate_kind_to_lsp <const>: {completion.CandidateKind:integer} = {
   field = lsp.completion_item_kind.Field,
   method = lsp.completion_item_kind.Method,
   ["function"] = lsp.completion_item_kind.Function,
   variable = lsp.completion_item_kind.Variable,
   keyword = lsp.completion_item_kind.Keyword,
   enum_member = lsp.completion_item_kind.EnumMember,
   module = lsp.completion_item_kind.Module,
}

local function type_kind_to_lsp(ti: tl.TypeInfo): integer
   if ti and ti.t == tl.typecodes.ENUM then
      return lsp.completion_item_kind.Enum
   elseif ti and ti.t == tl.typecodes.INTERFACE then
      return lsp.completion_item_kind.Interface
   end
   return lsp.completion_item_kind.Class
end

-- Resolves the receiver of a member completion. The by_pos entry recorded by
-- tl is the answer; a plain name chain (`a.b.c`) whose position tl skipped
-- (for example in a statement the parser dropped) is resolved through the
-- current scope's symbols and record fields instead, which is still tl's own
-- data. Anything else yields nil: no members are guessed.
--
-- In a type position (`local x: m.T`) by_pos holds the whole annotation at
-- its start, not the qualifier, so only the name chain applies there.
local function completion_receiver(doc: Document, ctx: completion.Context): tl.TypeInfo
   if not ctx.in_type then
      local ti = doc:type_of_expression(ctx.receiver)
      if ti then
         return ti
      end
   end
   local tokens = doc:get_tokens()
   local names: {string} = {}
   for i = ctx.receiver.first, ctx.receiver.last do
      local t = tokens[i]
      if t.kind == "identifier" then
         table.insert(names, t.tk)
      elseif t.tk ~= "." then
         return nil
      end
   end
   local first = tokens[ctx.receiver.first]
   return doc:type_information_for_tokens(names, first.y - 1, first.x - 1)
end

function LanguageFeatureHandlers:_on_completion(params: lsp.Method.Params, id: integer): nil
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end
   local pos = doc:to_byte_position(params.position as lsp.Position)
   logger:info("Received request for completion at position: %s", pos)

   if self:_complete_require(params, id, pos) then
      return
   end

   local line = doc:get_line(pos.line)
   local ctx = completion.context(doc:get_tokens(), pos.line + 1, pos.character + 1,
      doc:syntax_hint_at(pos.line, pos.character), line:sub(pos.character + 1))
   logger:debug("Completion context: %s (prefix %q)", ctx.kind, ctx.prefix)

   if ctx.kind == "none" then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local report = doc:get_type_report()
   local path = doc.uri.path
   local candidates: {completion.Candidate}
   if ctx.kind == "member" then
      local receiver = completion_receiver(doc, ctx)
      if receiver == nil then
         logger:info("Completion receiver has no recorded type")
      end
      candidates = completion.member_candidates(report, receiver, ctx.op, ctx.in_type)
   elseif ctx.kind == "type" then
      candidates = completion.type_candidates(report, path, pos.line + 1, pos.character + 1, doc:get_type_positions())
   elseif ctx.kind == "declaration" then
      candidates = completion.keyword_candidates(completion.declaration_keywords)
   elseif ctx.kind == "constructor" and completion.constructor_candidates(report,
         semantic.type_at_key(report, path, ctx.table_open.y, ctx.table_open.x, 0), {})[1] then
      -- a record constructor: its fields, not the scope (a record has no
      -- positional entries)
      local table_type = semantic.type_at_key(report, path, ctx.table_open.y, ctx.table_open.x, 0)
      candidates = completion.constructor_candidates(report, table_type, ctx.present_keys)
   else
      candidates = completion.scope_candidates(report, path, pos.line + 1, pos.character + 1,
         doc:get_type_positions(), ctx.prefix_y, ctx.prefix_x)
      for _, c in ipairs(completion.keyword_candidates(completion.keywords)) do
         table.insert(candidates, c)
      end
   end

   local items: {any} = {}
   for _, c in ipairs(completion.sort(candidates)) do
      local item: {string:any}
      if c.type_info and c.kind ~= "keyword" then
         item = self:_completion_item(doc, c.label, c.type_info, c.colon_call or false, ctx.followed_by_call)
      else
         item = { label = c.label }
      end
      if ctx.kind == "constructor" then
         item.kind = lsp.completion_item_kind.Field
         item.insertText = c.label .. " = "
         item.insertTextFormat = nil
      elseif c.kind == "type" then
         item.kind = type_kind_to_lsp(c.type_info)
      else
         item.kind = candidate_kind_to_lsp[c.kind] or item.kind
      end
      item.sortText = string.format("%02d_%s", c.tier, c.label)
      table.insert(items, item)
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
   local tokens = doc:get_tokens()
   local paren, active_arg, method_call = enclosing_call(tokens, pos.line + 1, pos.character + 1)
   local lookup: lsp.Position
   if paren then
      lookup = lsp.position(paren.y - 1, paren.x - 1)
   else
      lookup = lsp.position(pos.line, pos.character - 1)
      active_arg = 0
   end

   -- the callee is located on tl's tokens, like a completion receiver, and
   -- its type read from where tl recorded it
   local type_info: tl.TypeInfo
   local callee_name: string
   if paren then
      local key = semantic.expression_key(tokens, ast_walk.token_index_at(tokens, paren.y, paren.x) - 1)
      if key then
         type_info = doc:type_of_expression(key)
         -- label `a.b:c(...)` for a name chain, else the last name
         local parts: {string} = {}
         for i = key.first, key.last do
            local t = tokens[i]
            if t.kind == "identifier" or t.tk == "." or t.tk == ":" then
               table.insert(parts, t.tk)
            else
               parts = {}
            end
         end
         if #parts > 0 and parts[1] ~= "." and parts[1] ~= ":" then
            callee_name = table.concat(parts)
         elseif tokens[key.last].kind == "identifier" then
            callee_name = tokens[key.last].tk
         end
      end
   end
   if type_info == nil then
      local node_info = handler_helper.get_node_info(self._document_manager, params, lookup)
      if node_info == nil or node_info.type ~= "(" then
         self._lsp_reader_writer:send_rpc(id, nil)
         return
      end
      logger:debug("Got nodeinfo: %s", node_info)
      type_info = doc:resolve_preceded_type(node_info, lookup)
      callee_name = node_info.preceded_by
   end
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
            label = lsp_formatter.create_function_string(candidate.str, args, callee_name)
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
