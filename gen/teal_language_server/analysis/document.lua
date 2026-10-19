local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local _module_name = "analysis.document"

local ServerState = require("teal_language_server.server_state")
local Uri = require("teal_language_server.util.uri")
local lsp = require("teal_language_server.lsp.protocol")
local LspReaderWriter = require("teal_language_server.lsp.reader_writer")
local class = require("teal_language_server.util.class")
local asserts = require("teal_language_server.util.asserts")
local logging = require("teal_language_server.logging")
local json = require("cjson")
local position = require("teal_language_server.util.position")
local engine = require("teal_language_server.analysis.diagnostics.engine")
local problem = require("teal_language_server.analysis.diagnostics.problem")
local fixer = require("teal_language_server.analysis.diagnostics.fixer")
local linter = require("teal_language_server.analysis.diagnostics.linter")
local doc_symbols = require("teal_language_server.analysis.symbols")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")

local logger = logging.get_logger(_module_name)

local ltreesitter = require("ltreesitter")
local teal_language = ltreesitter.require("teal", "teal")
local teal_parser = teal_language:parser()

local tl = require("tl")
local lfs = require("lfs")














local Document = { NodeInfo = {} }

























































function Document:__init(uri, content, version, lsp_reader_writer, server_state)
   asserts.is_not_nil(lsp_reader_writer)
   asserts.is_not_nil(server_state)

   self._uri = uri
   self._cache = {}
   self._content = content
   self._version = version
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
   self._tree = teal_parser:parse_string(self._content)
   self._tree_cursor = self._tree:root():create_cursor()
end

local function is_lua(fname)
   return fname:sub(-4) == ".lua"
end

function Document:_get_tokens()
   local cache = self._cache
   if not cache.tokens then
      cache.tokens, cache.err_tokens = tl.lex(self._content, self._uri.path)
      if not cache.err_tokens then
         cache.err_tokens = {}
      end
   end
   return cache.tokens, cache.err_tokens
end

function Document:_get_ast(tokens)
   local cache = self._cache
   if not cache.ast then
      local _
      cache.parse_errors = {}
      cache.ast, _ = tl.parse_program(tokens, cache.parse_errors, self._uri.path)
      logger:debug("parse_prog errors: %d", #cache.parse_errors)
   end
   return cache.ast, cache.parse_errors
end

function Document:_get_result(ast)
   local cache = self._cache
   if not cache.result then
      local lax = is_lua(self._uri.path)
      logger:info("Type checking document%s %s", lax and " (lax)" or "", self._uri.path)

      local opts = {
         feat_lax = lax and "on" or "off",
         feat_arity = "on",
      }

      cache.result = tl.check(
      ast, self._uri.path, opts, self._server_state:get_env())
   end
   return cache.result
end

function Document:get_type_report()
   local env = self._server_state:get_env()
   return env.reporter:get_report()
end

local function _get_node_at(ast, y, x)
   for _, node in ipairs(ast) do
      if node.y == y and node.x == x then
         return node
      end
   end
end

function Document:get_ast_node_at(type_info)
   if type_info.file == "" then
      return _get_node_at(self:_get_ast(), type_info.y, type_info.x)
   end

   local loaded_file = self._server_state:get_env().loaded[type_info.file]
   if loaded_file == nil then return nil end
   return _get_node_at(loaded_file.ast, type_info.y, type_info.x)
end


local declaration_tokens = {}
local declaration_mtimes = {}

function Document:_tokens_of_file(file)
   if file == "" or file == self._uri.path then
      return (self:_get_tokens())
   end
   local path = self._server_state:absolute_path(file)
   local mtime = lfs.attributes(path, "modification")
   if mtime == nil then
      return nil
   end
   if declaration_mtimes[path] ~= mtime then
      local fd = io.open(path, "rb")
      if not fd then
         return nil
      end
      local text = fd:read("*a")
      fd:close()
      declaration_tokens[path] = tl.lex(text, path)
      declaration_mtimes[path] = mtime
   end
   return declaration_tokens[path]
end






function Document:_function_type_arg_names(type_info)
   if type_info.y == nil or type_info.x == nil or type_info.file == nil then
      return nil
   end
   local tokens = self:_tokens_of_file(type_info.file)
   if tokens == nil then
      return nil
   end
   local idx = ast_walk.token_index_at(tokens, type_info.y, type_info.x)
   local tok = tokens[idx]
   if not (tok and tok.tk == "function" and tok.y == type_info.y and tok.x == type_info.x) then
      return nil
   end

   local i = idx + 1
   if tokens[i] and tokens[i].tk == "<" then
      while tokens[i] and tokens[i].tk ~= ">" do i = i + 1 end
      i = i + 1
   end
   if not (tokens[i] and tokens[i].tk == "(") then
      return nil
   end
   local names = {}
   local any_named = false
   local depth = 0
   local segment_start = true
   i = i + 1
   while tokens[i] do
      local t = tokens[i]
      if t.tk == "(" or t.tk == "{" or t.tk == "<" then
         depth = depth + 1
      elseif t.tk == ")" or t.tk == "}" or t.tk == ">" then
         if depth == 0 then
            break
         end
         depth = depth - 1
      elseif t.tk == "," and depth == 0 then
         segment_start = true
      elseif segment_start and depth == 0 then
         segment_start = false
         local nxt = tokens[i + 1]
         if t.tk == "self" or t.tk == "..." then
            table.insert(names, t.tk)
            any_named = true
         elseif t.kind == "identifier" and nxt and nxt.tk == ":" then
            table.insert(names, t.tk)
            any_named = true
         elseif t.tk == "?" and tokens[i + 1] and tokens[i + 1].kind == "identifier" and tokens[i + 2] and tokens[i + 2].tk == ":" then
            table.insert(names, tokens[i + 1].tk)
            any_named = true
         else
            table.insert(names, "_")
         end
      end
      i = i + 1
   end
   if not any_named then
      return nil
   end
   return names
end

function Document:get_function_args_string(type_info)
   local node = self:get_ast_node_at(type_info)
   if node == nil then
      return self:_function_type_arg_names(type_info)
   end
   local output = {}
   for _, arg_info in ipairs(node.args) do
      table.insert(output, arg_info.tk)
   end
   return output
end


function Document:get_line(line)
   if not self._content_lines then
      self._content_lines = position.split_lines(self._content)
   end
   return self._content_lines[line + 1] or ""
end



function Document:to_lsp_position(y, x)
   local line = math.max(y - 1, 0)
   return lsp.position(line, position.byte_to_utf16(self:get_line(line), x - 1))
end



function Document:to_byte_position(pos)
   return lsp.position(pos.line, position.utf16_to_byte(self:get_line(pos.line), pos.character))
end


function Document:byte_to_lsp_position(line, byte_col)
   return lsp.position(line, position.byte_to_utf16(self:get_line(line), byte_col))
end

function Document:clear_cache()
   self._cache = {}
   logger:debug("Cleared cache for document %s", self._uri)
end

function Document:update_text(text, version)
   logger:debug("document update_text called (version %s)", version)

   if not version or not self._version or self._version < version then
      self:clear_cache()

      self._content = text
      self._content_lines = nil
      if version then
         self._version = version
      end
   end


   self._tree = teal_parser:parse_string(self._content)
   self._tree_cursor = self._tree:root():create_cursor()
end

function Document:_publish_diagnostics(diagnostics, version)
   logger:debug("Publishing diagnostics for %s...", self._uri.path)


   setmetatable(diagnostics, json.empty_array_mt)
   self._lsp_reader_writer:send_rpc_notification("textDocument/publishDiagnostics", {
      uri = Uri.tostring(self._uri),
      diagnostics = diagnostics,
      version = version,
   })
end



function Document:get_problems()
   local cache = self._cache
   if cache.problems then
      return cache.problems
   end

   local tks, lex_errs = self:_get_tokens()
   local input = {
      filename = self._uri.path,
      content = self._content,
      is_lua = is_lua(self._uri.path),
      tokens = tks,
      lex_errors = lex_errs,
      settings = self._server_state.lint_settings,
   }
   logger:debug("Detected %d lex errors", #lex_errs)
   if #lex_errs == 0 then
      local ast, parse_errs = self:_get_ast(tks)
      input.ast = ast
      input.parse_errors = parse_errs
      logger:debug("Detected %d parse errors", #parse_errs)
      if #parse_errs == 0 then
         input.result = self:_get_result(ast)
         input.report = self:get_type_report()
      end
   end

   cache.problems = engine.run(input)
   return cache.problems
end

local severity_to_lsp = {
   error = lsp.severity.Error,
   warning = lsp.severity.Warning,
   info = lsp.severity.Information,
   hint = lsp.severity.Hint,
}

local tag_to_lsp = {
   unnecessary = lsp.diagnostic_tag.Unnecessary,
   deprecated = lsp.diagnostic_tag.Deprecated,
}

function Document:to_lsp_range(y, x, yend, xend)
   return {
      start = self:to_lsp_position(y, x),
      ["end"] = self:to_lsp_position(yend, xend),
   }
end

function Document:problem_to_diagnostic(p)
   local tags
   for _, t in ipairs(p.tags or {}) do
      tags = tags or {}
      table.insert(tags, tag_to_lsp[t])
   end
   return {
      range = self:to_lsp_range(p.y, p.x, p.yend, p.xend),
      severity = severity_to_lsp[p.severity],
      message = p.message,
      code = p.rule_id,
      source = "teal",
      tags = tags,
      data = { version = self._version },
   }
end


function Document:get_symbols()
   local cache = self._cache
   if not cache.symbols then
      local tks = self:_get_tokens()
      local ast = self:_get_ast(tks)
      local ok, result = pcall(doc_symbols.document_symbols, tks, ast)
      if ok then
         cache.symbols = result
      else
         logger:error("Computing document symbols failed for %s: %s", self._uri.path, tostring(result))
         cache.symbols = {}
      end
   end
   return cache.symbols
end


function Document:get_dependency_files()
   local out = {}
   local result = self._cache.result
   if result and result.dependencies then
      for _, file in pairs(result.dependencies) do
         table.insert(out, self._server_state:absolute_path(file))
      end
   end
   table.sort(out)
   return out
end


function Document:get_tokens()
   return (self:_get_tokens())
end

function Document:get_ast()
   local tks = self:_get_tokens()
   return (self:_get_ast(tks))
end





function Document:compute_fix_all()
   local max_passes = 10
   local text = self._content
   local problems = self:get_problems()
   local config = self._server_state.config or {}
   local env_options = {
      defaults = self._server_state:get_env().defaults,
      predefined_modules = { config.global_env_def },
   }
   for _ = 1, max_passes do
      local fixes = {}
      for _, p in ipairs(problems) do
         if p.fix then
            table.insert(fixes, p.fix)
         end
      end
      if #fixes == 0 then
         break
      end
      local new_text, applied = fixer.apply_fixes(text, fixes)
      if applied == 0 or new_text == text then
         break
      end
      text = new_text
      if applied == #fixes then
         break
      end
      problems = linter.lint_text(text, self._uri.path, self._server_state.lint_settings, env_options)
   end
   if text == self._content then
      return nil
   end
   return text
end

function Document:process_and_publish_results()
   local diags = {}
   for _, p in ipairs(self:get_problems()) do
      table.insert(diags, self:problem_to_diagnostic(p))
   end
   self:_publish_diagnostics(diags, self._version)
end





function Document.split_by_symbols(input, self_type, stop_at)
   local t = {}
   if not input then return t end
   for str in string.gmatch(input, "([^%.%:]+)") do
      if str == "self" then
         table.insert(t, self_type)
      else
         table.insert(t, str)
      end
      if stop_at and stop_at == str then
         break
      end
   end
   return t
end

function Document:resolve_type_ref(type_number)
   local tr = self:get_type_report()
   local type_info = tr.types[type_number]
   if type_info and type_info.ref then
      return self:resolve_type_ref(type_info.ref)
   else
      return type_info
   end
end

















function Document:type_information_for_position(y, x, ret_depth)
   local tr = self:get_type_report()
   local file = tr.by_pos[self._uri.path]
   if file == nil or file[y] == nil then
      return nil
   end
   local type_id = file[y][x]
   if type_id == nil then
      return nil
   end
   local type_info = self:resolve_type_ref(type_id)



   for _ = 1, ret_depth or 0 do


      if type_info == nil or
         type_info.t ~= tl.typecodes.FUNCTION or
         type_info.rets == nil or
         type_info.rets[1] == nil then
         return nil
      end
      type_info = self:resolve_type_ref(type_info.rets[1][1])



      if type_info == nil or type_info.t == tl.typecodes.TYPE_VARIABLE then
         return nil
      end
   end

   return type_info
end

function Document:type_information_for_tokens(tokens, y, x)
   local tr = self:get_type_report()

   local type_info

   local scope_symbols = tl.symbols_in_scope(tr, y + 1, x + 1, self._uri.path)
   logger:trace("Looked up symbols at %d, %d for file %s with result: %s", y + 1, x + 1, self._uri.path, scope_symbols)
   if #tokens == 0 then
      local out = {}
      for key, value in pairs(scope_symbols) do out[key] = value end
      for key, value in pairs(tr.globals) do out[key] = value end
      type_info = {
         fields = out,
      }
      return type_info
   end
   local raw_token = tokens[1]
   logger:trace("Processing token %s (all: %s)", raw_token, tokens)
   local type_id = scope_symbols[raw_token]
   if type_id == nil then
      logger:info("Failed to find type id for token %s", raw_token)
   end
   if type_id ~= nil then
      logger:trace("Matched token %s to type id %s", raw_token, type_id)
      type_info = self:resolve_type_ref(type_id)

      if type_info == nil then
         logger:warning("Failed to resolve type ref for id")
      end
   end


   if type_info == nil then
      type_info = tr.types[tr.globals[raw_token]]

      if type_info == nil then
         logger:info("Unable to find type info in global table as well..")
      end
   end

   logger:debug("Got type info: %s", type_info)

   if type_info and #tokens > 1 then
      for i = 2, #tokens do
         logger:trace("tokens[i]: %s", tokens[i])

         if type_info.fields then
            type_info = self:resolve_type_ref(type_info.fields[tokens[i]])

         elseif type_info.values and i == #tokens then
            type_info = self:resolve_type_ref(type_info.values)




         end

         if type_info == nil then break end
      end
   end

   if type_info then
      logger:trace("Successfully found type info")
      return type_info
   end

   logger:info("Failed to find type info at given position")
   return nil
end




function Document:resolve_preceded_type(node_info, pos)
   if node_info.bypos_y then
      local type_info = self:type_information_for_position(node_info.bypos_y, node_info.bypos_x, node_info.bypos_ret_depth)
      if type_info ~= nil then
         logger:debug("Resolved preceded expr via by_pos at %d:%d", node_info.bypos_y, node_info.bypos_x)
         return type_info
      end
   end
   local tks = Document.split_by_symbols(node_info.preceded_by, node_info.self_type)
   logger:debug("Falling back to token chain: %s", tks)
   return self:type_information_for_tokens(tks, pos.line, pos.character)
end





function Document:symbol_declaration_position(name, y, x)
   local tr = self:get_type_report()
   local symbols = tr.symbols_by_file[self._uri.path]
   if not symbols then
      return nil
   end




   local target_y = y + 1
   local target_x = x + 1
   local n = 0
   for i = 1, #symbols do
      local s = symbols[i]
      if s[1] < target_y or (s[1] == target_y and s[2] <= target_x) then
         n = i
      else
         break
      end
   end



   while n >= 1 do
      local s = symbols[n]
      local symbol_name = s[3]
      if symbol_name == "@{" then
         n = n - 1
      elseif symbol_name == "@}" then
         n = s[4]
      else
         if symbol_name == name then
            return s[1], s[2]
         end
         n = n - 1
      end
   end

   return nil
end










local function bypos_key_for(node)
   if node == nil then
      return nil
   end
   local node_type = node:type()
   if node_type == "function_call" then
      local called = node:child_by_field_name("called_object")
      if called == nil then
         return nil
      end



      local y, x, depth = bypos_key_for(called)
      if y == nil then
         return nil
      end
      return y, x, (depth or 0) + 1
   elseif node_type == "index" or node_type == "method_index" then


      for child in node:children() do
         local child_type = child:type()
         if child_type == "." or child_type == ":" or child_type == "[" then
            local sp = child:start_point()
            return sp.row + 1, sp.column + 1
         end
      end
   end
   local start_point = node:start_point()
   return start_point.row + 1, start_point.column + 1
end

function Document:_tree_sitter_token(y, x)
   local moved = self._tree_cursor:goto_first_child()
   local node = self._tree_cursor:current_node()

   if moved == false then
      self._tree_cursor:goto_parent()

      local parent_node = self._tree_cursor:current_node()

      local node_start = node:start_point()
      local node_end = node:end_point()
      local out = {
         type = node:type(),
         source = node:source(),
         parent_type = parent_node:type(),
         parent_source = parent_node:source(),
         start_line = node_start.row,
         start_col = node_start.column,
         end_line = node_end.row,
         end_col = node_end.column,
      }


      if node:type() == "." or node:type() == ":" then

         local prev = node:prev_sibling()
         if prev then
            out.preceded_by = prev:source()


            out.bypos_y, out.bypos_x, out.bypos_ret_depth = bypos_key_for(prev)
         else
            parent_node = parent_node:prev_sibling()
            if parent_node then
               if parent_node:child_count() > 0 then

                  local last = parent_node:child(parent_node:child_count() - 1)
                  out.preceded_by = last:source()
                  out.bypos_y, out.bypos_x, out.bypos_ret_depth = bypos_key_for(last)
               else
                  out.preceded_by = parent_node:source()
                  out.bypos_y, out.bypos_x, out.bypos_ret_depth = bypos_key_for(parent_node)
               end
            end
         end


      elseif node:type() == "(" then
         if parent_node:type() == "arguments" then
            moved = self._tree_cursor:goto_parent()
            if moved == true then
               local function_call = self._tree_cursor:current_node():child_by_field_name("called_object")
               if function_call then
                  out.preceded_by = function_call:source()
                  out.bypos_y, out.bypos_x, out.bypos_ret_depth = bypos_key_for(function_call)
               end
            end

         elseif parent_node:type() == "ERROR" then
            for child in parent_node:children() do
               if child:name() == "index" then
                  out.preceded_by = child:source()
                  out.bypos_y, out.bypos_x, out.bypos_ret_depth = bypos_key_for(child)
                  break
               end
            end
         end




      elseif node:type() == "identifier" then
         local prev = node:prev_sibling()
         local key_node = (prev and (prev:type() == "." or prev:type() == ":")) and prev or node
         local sp = key_node:start_point()
         out.bypos_y = sp.row + 1
         out.bypos_x = sp.column + 1
      end

      if out.preceded_by == "self" or
         out.source:find("self[%.%:]") or
         out.parent_source:find("self[%.%:]") then

         while parent_node:type() ~= "program" do
            moved = self._tree_cursor:goto_parent()
            if moved == false then break end

            parent_node = self._tree_cursor:current_node()
            if parent_node:type() == "function_statement" then
               local function_name = parent_node:child_by_field_name("name")
               if function_name then
                  local base_name = function_name:child_by_field_name("base")
                  if base_name then
                     out.self_type = base_name:source()
                     break
                  end
               end
            elseif parent_node:type() == "ERROR" then

               for child in parent_node:children() do
                  if child:name() == "function_name" then
                     out.self_type = child:child_by_field_name("base"):source()
                     break
                  end
               end
            end
         end

      end

      return out

   end

   local start_point = node:start_point()
   local end_point = node:end_point()

   while moved do
      start_point = node:start_point()
      end_point = node:end_point()

      local after_start = y > start_point.row or (y == start_point.row and x >= start_point.column)
      local before_end = y < end_point.row or (y == end_point.row and x < end_point.column)
      if after_start and before_end then
         return self:_tree_sitter_token(y, x)
      end

      moved = self._tree_cursor:goto_next_sibling()
      node = self._tree_cursor:current_node()
   end
end

function Document:tree_sitter_token(y, x)
   self._tree_cursor:reset(self._tree:root())
   return self:_tree_sitter_token(y, x)
end

class.setup(Document, "Document", {
   getters = {
      uri = function(self)
         return self._uri
      end,
      version = function(self)
         return self._version
      end,
      content = function(self)
         return self._content
      end,
   },
   nilable_members = { '_content_lines' },
})
return Document
