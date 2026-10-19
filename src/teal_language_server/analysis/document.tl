local _module_name = "analysis.document"
-- <imports>
local ServerState <const> = require("teal_language_server.server_state")
local Uri <const> = require("teal_language_server.util.uri")
local lsp <const> = require("teal_language_server.lsp.protocol")
local LspReaderWriter <const> = require("teal_language_server.lsp.reader_writer")
local class <const> = require("teal_language_server.util.class")
local asserts <const> = require("teal_language_server.util.asserts")
local logging <const> = require("teal_language_server.logging")
local json <const> = require("cjson")
local position <const> = require("teal_language_server.util.position")
local engine <const> = require("teal_language_server.analysis.diagnostics.engine")
local problem <const> = require("teal_language_server.analysis.diagnostics.problem")
local fixer <const> = require("teal_language_server.analysis.diagnostics.fixer")
local linter <const> = require("teal_language_server.analysis.diagnostics.linter")
local doc_symbols <const> = require("teal_language_server.analysis.symbols")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")

local logger = logging.get_logger(_module_name)

local ltreesitter <const> = require("ltreesitter")
local teal_language = ltreesitter.require("teal", "teal")
local teal_parser = teal_language:parser()

local tl <const> = require("tl")
local lfs <const> = require("lfs")

local record Cache
   tokens: {tl.Token}
   err_tokens: {tl.Error}

   ast: tl.Node
   parse_errors: {tl.Error}

   result: tl.Result

   problems: {problem.Problem}
   symbols: {doc_symbols.Symbol}
end

local record Document
   record NodeInfo
      type: string
      source: string
      parent_type: string
      parent_source: string
      preceded_by: string
      self_type: string
      -- the (1-indexed) position to look this request's type up in by_pos:
      -- for completion the preceding expression's result, for signature help the
      -- called object, for hover the identifier under the cursor
      bypos_y: integer
      bypos_x: integer
      -- when the preceding expression is a function call, bypos_(y,x) points at
      -- the *called object* (whose function type stock tl does record) rather than
      -- the call result (a tuple stock tl skips); this holds the number of return
      -- levels to follow to recover the call's result type. Nested calls (f()())
      -- accumulate levels, one rets[1] hop per call.
      bypos_ret_depth: integer
      -- 0-based byte span of the node under the cursor (tree-sitter convention)
      start_line: integer
      start_col: integer
      end_line: integer
      end_col: integer
      metamethod __tostring: function(NodeInfo): string
   end

   uri: Uri
   version: integer
   content: string

   _uri: Uri
   _content: string
   _content_lines: {string}
   _version: integer
   _lsp_reader_writer: LspReaderWriter
   _server_state: ServerState
   _cache: Cache
   _tree: ltreesitter.Tree
   _tree_cursor: ltreesitter.Cursor

   metamethod __call: function(self: Document, uri: Uri, content: string, version: integer, lsp_reader_writer: LspReaderWriter, server_state: ServerState): Document
end

local record ArgListNode is tl.Node
    record ArgType
        typename: string
    end

    record ArgInfo
        tk: string
        opt: boolean
        argtype: ArgType
    end

    args: {ArgInfo}
end

function Document:__init(uri: Uri, content: string, version: integer, lsp_reader_writer: LspReaderWriter, server_state: ServerState)
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

local function is_lua(fname: string): boolean
   return fname:sub(-4) == ".lua"
end

function Document:_get_tokens(): {tl.Token}, {tl.Error}
   local cache = self._cache
   if not cache.tokens then
      cache.tokens, cache.err_tokens = tl.lex(self._content, self._uri.path)
      if not cache.err_tokens then
         cache.err_tokens = {}
      end
   end
   return cache.tokens, cache.err_tokens
end

function Document:_get_ast(tokens?: {tl.Token}): tl.Node, {tl.Error}
   local cache = self._cache
   if not cache.ast then
      local _: any
      cache.parse_errors = {}
      cache.ast, _ = tl.parse_program(tokens, cache.parse_errors, self._uri.path)
      logger:debug("parse_prog errors: %d", #cache.parse_errors)
   end
   return cache.ast, cache.parse_errors
end

function Document:_get_result(ast: tl.Node): tl.Result
   local cache = self._cache
   if not cache.result then
      local lax = is_lua(self._uri.path)
      logger:info("Type checking document%s %s", lax and " (lax)" or "", self._uri.path)

      local opts: tl.CheckOptions = {
         feat_lax = lax and "on" or "off",
         feat_arity = "on",
      }

      cache.result = tl.check(
         ast, self._uri.path, opts, self._server_state:get_env())
   end
   return cache.result
end

function Document:get_type_report(): tl.TypeReport
   local env = self._server_state:get_env()
   return env.reporter:get_report()
end

local function _get_node_at(ast: tl.Node, y: integer, x: integer): tl.Node
   for _, node in ipairs(ast) do
      if node.y == y and node.x == x then
         return node
      end
   end
end

function Document:get_ast_node_at(type_info: tl.TypeInfo): tl.Node
   if type_info.file == "" then
      return _get_node_at(self:_get_ast(), type_info.y, type_info.x)
   end

   local loaded_file = self._server_state:get_env().loaded[type_info.file]
   if loaded_file == nil then return nil end
   return _get_node_at(loaded_file.ast, type_info.y, type_info.x)
end

-- lexed declaration files, for reading parameter names of function types
local declaration_tokens: {string:{tl.Token}} = {}
local declaration_mtimes: {string:number} = {}

function Document:_tokens_of_file(file: string): {tl.Token}
   if file == "" or file == self._uri.path then
      return (self:_get_tokens())
   end
   local path = self._server_state:absolute_path(file)
   local mtime = lfs.attributes(path, "modification") as number
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

-- Parameter names of a function *type* written in a declaration, such as a
-- record field `create: function(self, name: string): T`. tl's type report
-- does not keep these names, but it does record where the type was written,
-- so the parameter list is read from the lexer tokens at that position.
-- Unnamed parameters get "_"; returns nil if no parameter is named.
function Document:_function_type_arg_names(type_info: tl.TypeInfo): {string}
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
   -- skip generic parameters: function<T>(...)
   local i = idx + 1
   if tokens[i] and tokens[i].tk == "<" then
      while tokens[i] and tokens[i].tk ~= ">" do i = i + 1 end
      i = i + 1
   end
   if not (tokens[i] and tokens[i].tk == "(") then
      return nil
   end
   local names: {string} = {}
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

function Document:get_function_args_string(type_info: tl.TypeInfo): {string}
   local node = self:get_ast_node_at(type_info) as ArgListNode
   if node == nil then
      return self:_function_type_arg_names(type_info)
   end
   local output: {string} = {}
   for _, arg_info in ipairs(node.args) do
      table.insert(output, arg_info.tk)
   end
   return output
end

-- Returns the text of the 0-based line `line`, or "" when out of range.
function Document:get_line(line: integer): string
   if not self._content_lines then
      self._content_lines = position.split_lines(self._content)
   end
   return self._content_lines[line + 1] or ""
end

-- Converts a tl position (1-based line, 1-based byte column) into an LSP
-- position (0-based line, 0-based UTF-16 column).
function Document:to_lsp_position(y: integer, x: integer): lsp.Position
   local line = math.max(y - 1, 0)
   return lsp.position(line, position.byte_to_utf16(self:get_line(line), x - 1))
end

-- Converts an incoming LSP position (UTF-16 columns) into a 0-based byte
-- position, which is what tree-sitter and the rest of the analysis use.
function Document:to_byte_position(pos: lsp.Position): lsp.Position
   return lsp.position(pos.line, position.utf16_to_byte(self:get_line(pos.line), pos.character))
end

-- Converts a 0-based byte position (tree-sitter convention) into an LSP position.
function Document:byte_to_lsp_position(line: integer, byte_col: integer): lsp.Position
   return lsp.position(line, position.byte_to_utf16(self:get_line(line), byte_col))
end

function Document:clear_cache()
   self._cache = {}
   logger:debug("Cleared cache for document %s", self._uri)
end

function Document:update_text(text: string, version: integer)
   logger:debug("document update_text called (version %s)", version)

   if not version or not self._version or self._version < version then
      self:clear_cache()

      self._content = text
      self._content_lines = nil
      if version then
         self._version = version
      end
   end

   -- update tree and tree cursor as well
   self._tree = teal_parser:parse_string(self._content)
   self._tree_cursor = self._tree:root():create_cursor()
end

function Document:_publish_diagnostics(diagnostics: {lsp.Diagnostic}, version?: number)
   logger:debug("Publishing diagnostics for %s...", self._uri.path)
   -- cjson encodes an empty table as {} (object) rather than [] (array).
   -- Setting empty_array_mt ensures empty diagnostics serialize as [] per LSP spec.
   setmetatable(diagnostics, json.empty_array_mt as metatable<{lsp.Diagnostic}>)
   self._lsp_reader_writer:send_rpc_notification("textDocument/publishDiagnostics", {
      uri = Uri.tostring(self._uri),
      diagnostics = diagnostics,
      version = version,
   } as lsp.Method.Params)
end

-- Runs (or returns the cached result of) the diagnostics engine: compiler
-- problems, lint rules and suppression directives, in deterministic order.
function Document:get_problems(): {problem.Problem}
   local cache = self._cache
   if cache.problems then
      return cache.problems
   end

   local tks, lex_errs = self:_get_tokens()
   local input: engine.Input = {
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

local severity_to_lsp: {problem.Severity:integer} = {
   error = lsp.severity.Error,
   warning = lsp.severity.Warning,
   info = lsp.severity.Information,
   hint = lsp.severity.Hint,
}

local tag_to_lsp: {problem.Tag:integer} = {
   unnecessary = lsp.diagnostic_tag.Unnecessary,
   deprecated = lsp.diagnostic_tag.Deprecated,
}

function Document:to_lsp_range(y: integer, x: integer, yend: integer, xend: integer): lsp.Range
   return {
      start = self:to_lsp_position(y, x),
      ["end"] = self:to_lsp_position(yend, xend),
   }
end

function Document:problem_to_diagnostic(p: problem.Problem): lsp.Diagnostic
   local tags: {integer}
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

-- Outline of the document (parse tree only; works with type errors).
function Document:get_symbols(): {doc_symbols.Symbol}
   local cache = self._cache
   if not cache.symbols then
      local tks = self:_get_tokens()
      local ast = self:_get_ast(tks)
      local ok, result = pcall(doc_symbols.document_symbols, tks, ast as ast_walk.AstNode)
      if ok then
         cache.symbols = result as {doc_symbols.Symbol}
      else
         logger:error("Computing document symbols failed for %s: %s", self._uri.path, tostring(result))
         cache.symbols = {}
      end
   end
   return cache.symbols
end

-- Files of the modules this document required in its last type check.
function Document:get_dependency_files(): {string}
   local out: {string} = {}
   local result = self._cache.result
   if result and result.dependencies then
      for _, file in pairs(result.dependencies) do
         table.insert(out, self._server_state:absolute_path(file))
      end
   end
   table.sort(out)
   return out
end

-- Public accessors for the cached lexer/parser output.
function Document:get_tokens(): {tl.Token}
   return (self:_get_tokens())
end

function Document:get_ast(): tl.Node
   local tks = self:_get_tokens()
   return (self:_get_ast(tks))
end

-- Applies every safe fix (never suggestions), ESLint-style: non-overlapping
-- fixes are applied together; if some had to be deferred, the result is
-- re-linted in memory and the process repeats, up to 10 passes. Returns the
-- fixed text, or nil if nothing changed.
function Document:compute_fix_all(): string
   local max_passes <const> = 10
   local text = self._content
   local problems = self:get_problems()
   local config = self._server_state.config or {}
   local env_options: tl.EnvOptions = {
      defaults = self._server_state:get_env().defaults,
      predefined_modules = { config.global_env_def },
   }
   for _ = 1, max_passes do
      local fixes: {problem.Fix} = {}
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
   local diags: {lsp.Diagnostic} = {}
   for _, p in ipairs(self:get_problems()) do
      table.insert(diags, self:problem_to_diagnostic(p))
   end
   self:_publish_diagnostics(diags, self._version)
end

-- Split a dotted/colon source string (e.g. "self.foo.bar") into a token chain,
-- substituting the enclosing record name for "self". Stops after `stop_at` when
-- given. Pure string parsing over NodeInfo-derived text; feeds
-- type_information_for_tokens.
function Document.split_by_symbols(input: string, self_type: string, stop_at?: string): {string}
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

function Document:resolve_type_ref(type_number: integer): tl.TypeInfo
   local tr <const> = self:get_type_report()
   local type_info = tr.types[type_number]
   if type_info and type_info.ref then
      return self:resolve_type_ref(type_info.ref)
   else
      return type_info
   end
end

-- Resolves the type of an expression directly from its source position via the
-- type report's by_pos map. y/x are 1-indexed (tl convention).
--
-- Stock tl records a single-value result at its position (locals, globals, plain
-- field access), but skips a function call's *result* because it is a tuple. To
-- still resolve a call, callers point y/x at the *called object* (whose function
-- type tl does record) and pass ret_depth = the number of return levels to follow;
-- we then follow the function's first return value (rets[1]) that many times to
-- recover the call's result type. A double call like f()() passes ret_depth=2.
--
-- One case stays unresolvable from the report alone: a generic function whose
-- return is a bare, unconstrained type variable (e.g. `first<T>(...): T`). tl
-- records the declaration-site `T` with no constraint or fields, so following
-- rets yields an empty typevar and we return nil; callers fall back to
-- type_information_for_tokens. (See PR #74 for the tl patch that fixed that case
-- in the checker itself.)
function Document:type_information_for_position(y: integer, x: integer, ret_depth?: integer): tl.TypeInfo
   local tr <const> = self:get_type_report()
   local file = tr.by_pos[self._uri.path]
   if file == nil or file[y] == nil then
      return nil
   end
   local type_id = file[y][x]
   if type_id == nil then
      return nil
   end
   local type_info = self:resolve_type_ref(type_id)

   -- the by_pos entry is the callable itself; follow one rets[1] per call level
   -- (nested calls like f()() need more than one hop).
   for _ = 1, ret_depth or 0 do
      -- not a plain function (e.g. a POLY/overload) or no returns: bail so the
      -- caller falls back to token resolution.
      if type_info == nil
         or type_info.t ~= tl.typecodes.FUNCTION
         or type_info.rets == nil
         or type_info.rets[1] == nil then
         return nil
      end
      type_info = self:resolve_type_ref(type_info.rets[1][1])
      -- a return that resolves to a bare type variable (e.g. generic `T`) carries
      -- no constraint or fields in the report, so it is unusable; treat it as a
      -- miss and let the caller fall back to token resolution
      if type_info == nil or type_info.t == tl.typecodes.TYPE_VARIABLE then
         return nil
      end
   end

   return type_info
end

function Document:type_information_for_tokens(tokens: {string}, y: integer, x: integer): tl.TypeInfo
   local tr <const> = self:get_type_report()

   local type_info: tl.TypeInfo
   -- try and find it in scope
   local scope_symbols <const> = tl.symbols_in_scope(tr, y+1, x+1, self._uri.path)
   logger:trace("Looked up symbols at %d, %d for file %s with result: %s", y+1, x+1, self._uri.path, scope_symbols)
   if #tokens == 0 then
      local out = {}
      for key, value in pairs(scope_symbols) do out[key] = value end
      for key, value in pairs(tr.globals) do out[key] = value end
      type_info = {
         fields = out
      }
      return type_info
   end
   local raw_token = tokens[1]
   logger:trace("Processing token %s (all: %s)", raw_token, tokens)
   local type_id <const> = scope_symbols[raw_token]
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

   -- might be global instead
   if type_info == nil then
      type_info = tr.types[tr.globals[raw_token] ]

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

         -- else
         --    tracing.warning(_module_name, "Something odd is going on here bruv '{}'", type_info)

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

-- Resolve the type of the expression preceding a '.'/':'/'(' trigger. Prefers the
-- direct by_pos lookup (handles calls, method chains, dotted access); on a miss,
-- falls back to re-parsing node_info.preceded_by into a token chain.
function Document:resolve_preceded_type(node_info: Document.NodeInfo, pos: lsp.Position): tl.TypeInfo
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

-- Finds where a symbol named `name` was *declared* (as opposed to where its type
-- is declared). Mirrors the backward scope walk in tl.symbols_in_scope, but
-- returns the matched symbol's declaration position instead of its type id.
-- `y`/`x` are 0-indexed (LSP); the returned y/x are 1-indexed (tl convention).
function Document:symbol_declaration_position(name: string, y: integer, x: integer): integer, integer
   local tr <const> = self:get_type_report()
   local symbols = tr.symbols_by_file[self._uri.path]
   if not symbols then
      return nil
   end

   -- Symbols are stored in source order, so the last one whose position is at or
   -- before the cursor is our starting point. (tl uses a binary search here, but
   -- that helper is private to tl, so we scan linearly.)
   local target_y <const> = y + 1
   local target_x <const> = x + 1
   local n = 0
   for i = 1, #symbols do
      local s = symbols[i]
      if s[1] < target_y or (s[1] == target_y and s[2] <= target_x) then
         n = i
      else
         break
      end
   end

   -- Walk backwards, honoring the @{ / @} scope markers, and return the position
   -- of the nearest in-scope declaration matching `name`.
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

-- Map a tree-sitter expression node to the (1-indexed) position where tl records
-- its result type in by_pos, plus the number of return levels to follow so that
-- position holds the callable (rather than the value directly):
--   function_call      -> the *called object*'s position, ret_depth += 1. tl
--                         skips the call result (a tuple), but records the called
--                         object's function type, whose rets[1] is the result.
--                         Nested calls (f()()) accumulate levels.
--   index/method_index -> the "."/":"/"[" operator child; the access result lives there
--   anything else      -> the node's own start
local function bypos_key_for(node: ltreesitter.Node): integer, integer, integer
   if node == nil then
      return nil
   end
   local node_type = node:type()
   if node_type == "function_call" then
      local called = node:child_by_field_name("called_object")
      if called == nil then
         return nil
      end
      -- resolve the called object's by_pos position (identifier / index / method
      -- index) and add a return level so the lookup follows the function's first
      -- return value; nested calls accumulate one level per call.
      local y, x, depth = bypos_key_for(called)
      if y == nil then
         return nil
      end
      return y, x, (depth or 0) + 1
   elseif node_type == "index" or node_type == "method_index" then
      -- the access result is recorded at the operator: "." / ":" for field and
      -- method access, "[" for bracket indexing
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

function Document:_tree_sitter_token(y: integer, x: integer): Document.NodeInfo
   local moved: boolean = self._tree_cursor:goto_first_child()
   local node = self._tree_cursor:current_node()

   if moved == false then
      self._tree_cursor:goto_parent()

      local parent_node = self._tree_cursor:current_node()

      local node_start = node:start_point()
      local node_end = node:end_point()
      local out: Document.NodeInfo = {
         type = node:type(),
         source = node:source(),
         parent_type = parent_node:type(),
         parent_source = parent_node:source(),
         start_line = node_start.row,
         start_col = node_start.column,
         end_line = node_end.row,
         end_col = node_end.column,
      }

      -- for completion
      if node:type() == "." or node:type() == ":" then
         -- considered an error and need to get the previous symbol
         local prev = node:prev_sibling()
         if prev then
            out.preceded_by = prev:source()
            -- record where the preceding expression's result type lives in by_pos
            -- so completion can resolve it directly (calls, chains, dotted access)
            out.bypos_y, out.bypos_x, out.bypos_ret_depth = bypos_key_for(prev)
         else
            parent_node = parent_node:prev_sibling()
            if parent_node then
               if parent_node:child_count() > 0 then
                  -- no previous symbol, so get parent's previous sibling's last child
                  local last = parent_node:child(parent_node:child_count()-1)
                  out.preceded_by = last:source()
                  out.bypos_y, out.bypos_x, out.bypos_ret_depth = bypos_key_for(last)
               else
                  out.preceded_by = parent_node:source()
                  out.bypos_y, out.bypos_x, out.bypos_ret_depth = bypos_key_for(parent_node)
               end
            end
         end

      -- for function signature
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

      -- for hover: a cursor sitting on an identifier resolves via by_pos. A field
      -- access (preceded by "." / ":") has its result recorded at the operator,
      -- so look there; a plain variable resolves at its own position.
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
               -- for some reason you can't get the node by name in an error state, but you can still iterate over to it
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

function Document:tree_sitter_token(y: integer, x: integer): Document.NodeInfo
   self._tree_cursor:reset(self._tree:root())
   return self:_tree_sitter_token(y, x)
end

class.setup(Document, "Document", {
   getters =  {
      uri = function(self:Document):Uri
         return self._uri
      end,
      version = function(self:Document):integer
         return self._version
      end,
      content = function(self:Document):string
         return self._content
      end
   },
   nilable_members = { '_content_lines' },
})
return Document
