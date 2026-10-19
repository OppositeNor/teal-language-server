local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local _tl_math_maxinteger = math.maxinteger or math.pow(2, 53); local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local _module_name = "handlers.language_feature"

local handler_helper = require("teal_language_server.handlers.handler_helper")
local DocumentManager = require("teal_language_server.analysis.document_manager")
local ServerState = require("teal_language_server.server_state")
local workspace_index = require("teal_language_server.analysis.workspace_index")
local position = require("teal_language_server.util.position")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local inlay_hints = require("teal_language_server.analysis.inlay_hints")
local Document = require("teal_language_server.analysis.document")
local LspReaderWriter = require("teal_language_server.lsp.reader_writer")
local LspEventsManager = require("teal_language_server.lsp.events_manager")
local lsp = require("teal_language_server.lsp.protocol")
local logging = require("teal_language_server.logging")
local class = require("teal_language_server.util.class")
local tl = require("tl")
local lsp_formatter = require("teal_language_server.lsp.formatter")
local json = require("cjson")

local logger = logging.get_logger(_module_name)

local LanguageFeatureHandlers = {}








function LanguageFeatureHandlers:__init(lsp_events_manager, lsp_reader_writer, document_manager, server_state)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._document_manager = document_manager
   self._server_state = server_state
end

local TEAL_KEYWORDS = {
   "and", "break", "do", "else", "elseif", "end", "enum", "false", "for", "function",
   "global", "goto", "if", "in", "interface", "local", "nil", "not", "or", "record",
   "repeat", "return", "then", "true", "type", "until", "while",
}

local function is_callable(ti)
   return ti.t == tl.typecodes.FUNCTION or ti.t == tl.typecodes.POLY
end


local function snippet_escape(s)
   return (s:gsub("[%$}\\]", "\\%0"))
end





function LanguageFeatureHandlers:_completion_item(doc, key, ti, colon_access)
   local item = {
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
            local placeholders = {}
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



function LanguageFeatureHandlers:_complete_require(params, id, pos)
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      return false
   end
   local line = doc:get_line(pos.line)
   local before = line:sub(1, pos.character)
   local start_col = before:match("require%s*%(?%s*[\"']()[%w_%.%-]*$")
   if start_col == nil then
      return false
   end
   local index = self._server_state:get_workspace_index()
   workspace_index.refresh(index, function(path)
      return self._document_manager:open_content(path)
   end)
   local range = {
      start = lsp.position(pos.line, position.byte_to_utf16(line, start_col - 1)),
      ["end"] = lsp.position(pos.line, position.byte_to_utf16(line, pos.character)),
   }
   local items = {}
   for _, name in ipairs(workspace_index.module_names(index)) do
      table.insert(items, {
         label = name,
         kind = lsp.completion_item_kind.Module,
         textEdit = { range = range, newText = name },
      })
   end
   setmetatable(items, json.empty_array_mt)
   self._lsp_reader_writer:send_rpc(id, { isIncomplete = false, items = items })
   return true
end

function LanguageFeatureHandlers:_on_completion(params, id)
   local pos = handler_helper.byte_position(self._document_manager, params)
   logger:info("Received request for completion at position: %s", pos)

   if self:_complete_require(params, id, pos) then
      return
   end



   pos.character = pos.character - 1

   local node_info, doc = handler_helper.get_node_info(self._document_manager, params, pos)
   if node_info == nil then
      logger:trace("No node found at given position")
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   logger:debug("Found node info: %s", node_info)

   local type_info
   local scope_completion = false



   if node_info.type == "." or node_info.type == ":" then
      type_info = doc:resolve_preceded_type(node_info, pos)


   elseif node_info.type == "identifier" then
      local tks

      if handler_helper.indexable_parent_types[node_info.parent_type] then
         tks = Document.split_by_symbols(node_info.parent_source, node_info.self_type)
      else
         tks = Document.split_by_symbols(node_info.source, node_info.self_type)
      end




      tks[#tks] = nil



      if node_info.parent_type == "var" or
         node_info.parent_type == "simple_type" or
         node_info.parent_type == "table_type" then
         self._lsp_reader_writer:send_rpc(id, nil)
         return
      end

      type_info = doc:type_information_for_tokens(tks, pos.line, pos.character)

      scope_completion = #tks == 0
   else
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local items = {}

   if not type_info then
      logger:info("Also failed to find type type_info based on token")
   end

   if type_info then
      logger:debug("Successfully found type_info")
      local tr = doc:get_type_report()

      if type_info.ref then
         type_info = doc:resolve_type_ref(type_info.ref)
      end


      local was_string_type = type_info.t == tl.typecodes.STRING
      if was_string_type then
         type_info = tr.types[tr.globals["string"]]
      end




      local original_str = type_info.str



      local function is_self_method(fn)
         if fn.t ~= tl.typecodes.FUNCTION or not fn.args or #fn.args < 1 then
            return false
         end
         local first_arg_type = doc:resolve_type_ref(fn.args[1][1])
         return first_arg_type.t == tl.typecodes.SELF or
         ((first_arg_type.t == tl.typecodes.NOMINAL or first_arg_type.t == tl.typecodes.RECORD) and first_arg_type.str == original_str) or
         (was_string_type and first_arg_type.t == tl.typecodes.STRING)
      end

      if type_info.fields then
         for key, v in pairs(type_info.fields) do
            type_info = doc:resolve_type_ref(v)
            local was_added

            if node_info.type == ":" then


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


      elseif type_info.keys then
         type_info = doc:resolve_type_ref(type_info.keys)

         if type_info.enums then
            for _, enum_value in ipairs(type_info.enums) do
               table.insert(items, { label = enum_value, kind = lsp.typecodes_to_kind[type_info.t] })
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

   setmetatable(items, json.empty_array_mt)

   logger:debug("Sending %d back to client", #items)

   self._lsp_reader_writer:send_rpc(id, {
      isIncomplete = false,
      items = items,
   })
end






local function enclosing_call(tokens, y, x)

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


            commas = 0
         else
            depth = depth - 1
         end
      elseif tk == "(" then
         if depth == 0 then
            local prev = tokens[idx - 1]
            local before_prev = tokens[idx - 2]
            local callable = prev ~= nil and (prev.kind == "identifier" or prev.tk == ")" or prev.tk == "]" or prev.tk == "self")

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



local function label_parameter_ranges(label)
   local ranges = {}
   local open
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

   for _, r in ipairs(ranges) do
      while label:sub(r[1], r[1]) == " " and r[1] < r[2] do r[1] = r[1] + 1 end
      while label:sub(r[2] - 1, r[2] - 1) == " " and r[2] > r[1] do r[2] = r[2] - 1 end
   end
   return ranges
end

function LanguageFeatureHandlers:_on_signature_help(params, id)
   local pos = handler_helper.byte_position(self._document_manager, params)
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end



   local paren, active_arg, method_call = enclosing_call(doc:get_tokens(), pos.line + 1, pos.character + 1)
   local lookup
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

   local candidates = {}
   if type_info.t == tl.typecodes.POLY then
      for _, type_ref in ipairs(type_info.types) do
         table.insert(candidates, doc:resolve_type_ref(type_ref))
      end
   else
      table.insert(candidates, type_info)
   end

   local output = { signatures = {}, activeSignature = 0, activeParameter = 0 }
   for _, candidate in ipairs(candidates) do
      if candidate and candidate.str then
         local args = doc:get_function_args_string(candidate)
         local label
         if args ~= nil then
            label = lsp_formatter.create_function_string(candidate.str, args, node_info.preceded_by)
         else
            label = candidate.str
         end
         local parameters = {}
         for _, r in ipairs(label_parameter_ranges(label)) do
            table.insert(parameters, {
               label = { position.byte_to_utf16(label, r[1] - 1), position.byte_to_utf16(label, r[2] - 1) },
            })
         end

         local active = active_arg
         if method_call and args and args[1] == "self" then
            active = active + 1
         end
         table.insert(output.signatures, {
            label = label,
            parameters = setmetatable(parameters, json.empty_array_mt),
            activeParameter = active,
         })
      end
   end

   if #output.signatures == 0 then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end
   output.activeParameter = output.signatures[1].activeParameter
   self._lsp_reader_writer:send_rpc(id, output)
end

function LanguageFeatureHandlers:_on_hover(params, id)
   local pos = handler_helper.byte_position(self._document_manager, params)
   logger:trace("Received request for hover at position: %s", pos)
   local node_info, doc = handler_helper.get_node_info(self._document_manager, params, pos)
   if node_info == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local node_range = {
      start = doc:byte_to_lsp_position(node_info.start_line, node_info.start_col),
      ["end"] = doc:byte_to_lsp_position(node_info.end_line, node_info.end_col),
   }

   local tks = {}
   local quick_type_info
   if node_info.type == "identifier" then


      if node_info.bypos_y then
         quick_type_info = doc:type_information_for_position(node_info.bypos_y, node_info.bypos_x)
      end

      if quick_type_info == nil then

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

   local type_str = lsp_formatter.show_type(node_info, type_info, doc)
   self._lsp_reader_writer:send_rpc(id, {
      contents = type_str,
      range = node_range,
   })
end

function LanguageFeatureHandlers:_inlay_hints_enabled()
   local externals = (self._server_state.config or {}).externals
   local ours = externals and (externals).teal_language_server
   return not (type(ours) == "table" and (ours).inlay_hints == false)
end

function LanguageFeatureHandlers:_on_inlay_hint(params, id)
   local doc = handler_helper.get_document(self._document_manager, params)
   local result = {}
   if doc and self:_inlay_hints_enabled() then
      local range = params.range
      local first_line = range and range.start.line + 1 or 1
      local last_line = range and range["end"].line + 1 or _tl_math_maxinteger
      local report = doc:get_type_report()
      local by_pos = report.by_pos[doc.uri.path]
      local function type_str_at(y, x)
         local row = by_pos and by_pos[y]
         local type_id = row and row[x]
         local ti = type_id and report.types[type_id]
         return ti and ti.str
      end
      local ast = doc:get_ast()
      for _, h in ipairs(inlay_hints.compute(doc:get_tokens(), ast, type_str_at, first_line, last_line)) do
         table.insert(result, {
            position = doc:to_lsp_position(h.y, h.x),
            label = h.label,
            kind = 1,
         })
      end
   end
   setmetatable(result, json.empty_array_mt)
   self._lsp_reader_writer:send_rpc(id, result)
end

function LanguageFeatureHandlers:initialize()
   self._lsp_events_manager:set_handler("textDocument/completion", function(params, id) self:_on_completion(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/signatureHelp", function(params, id) self:_on_signature_help(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/hover", function(params, id) self:_on_hover(params, id) end)
   self._lsp_events_manager:set_handler("textDocument/inlayHint", function(params, id) self:_on_inlay_hint(params, id) end)
end

class.setup(LanguageFeatureHandlers, "LanguageFeatureHandlers", {})

return LanguageFeatureHandlers
