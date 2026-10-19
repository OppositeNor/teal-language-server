-- Semantic queries shared by the language features (completion, hover,
-- navigation). They work on plain inputs -- lexer tokens, the tl AST and the
-- type report -- and know nothing about LSP types, so they can be unit tested
-- in-process.
--
-- The tl type checker is the only semantic authority: these helpers locate
-- where tl recorded an answer, they never compute types themselves.
--
-- Positions are tl coordinates (1-based line, 1-based byte column).

local tl <const> = require("tl")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")

local type AstNode = ast_walk.AstNode

local record semantic
   -- A name visible at a position, from tl's symbol list
   record VisibleSymbol
      name: string
      -- where the name was declared
      y: integer
      x: integer
      type_id: integer
      -- 0 for the innermost scope, growing outwards
      depth: integer
   end

   -- Where tl recorded the type of an expression: by_pos[y][x], followed
   -- `ret_depth` times through the first return value (tl does not record a
   -- call's result, which is a tuple, but it records the called function).
   record ExprKey
      y: integer
      x: integer
      ret_depth: integer
      -- token span of the expression
      first: integer
      last: integer
      -- the expression contains a call
      has_call: boolean
   end
end

-- Follows NOMINAL references to the type they name.
function semantic.resolve(report: tl.TypeReport, type_id: integer): tl.TypeInfo
   local ti = type_id and report.types[type_id]
   local guard = 0
   while ti and ti.ref and guard < 100 do
      ti = report.types[ti.ref]
      guard = guard + 1
   end
   return ti
end

-- Names visible at (y, x) in `file`, innermost declaration first. Mirrors the
-- backwards walk of tl.symbols_in_scope over the `@{` / `@}` scope markers,
-- but keeps declaration positions and scope depth.
function semantic.visible_symbols(report: tl.TypeReport, file: string, y: integer, x: integer): {semantic.VisibleSymbol}
   local out: {semantic.VisibleSymbol} = {}
   local symbols = report.symbols_by_file[file]
   if not symbols then
      return out
   end
   local n = 0
   local lo, hi = 1, #symbols
   while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local s = symbols[mid]
      if s[1] < y or (s[1] == y and s[2] <= x) then
         n = mid
         lo = mid + 1
      else
         hi = mid - 1
      end
   end
   local seen: {string:boolean} = {}
   local depth = 0
   while n >= 1 do
      local s = symbols[n]
      local name = s[3]
      if name == "@{" then
         depth = depth + 1
         n = n - 1
      elseif name == "@}" then
         n = s[4]
      else
         if not seen[name] then
            seen[name] = true
            table.insert(out, { name = name, y = s[1], x = s[2], type_id = s[4], depth = depth })
         end
         n = n - 1
      end
   end
   return out
end

-- Positions ("y:x") of names declared as types (`local record P`,
-- `local type T = ...`, `global type G`, enums, interfaces), anywhere in the
-- AST. tl's type report collapses a type declaration into the declared type,
-- which makes `local record P` look like a value of a record type; the
-- declaration statement is what tells them apart.
function semantic.type_declaration_positions(ast: tl.Node): {string:string}
   local out: {string:string} = {}
   if ast == nil then
      return out
   end
   local function mark(node: AstNode)
      local var = (node as {string:any}).var as AstNode
      if var and var.y and var.x then
         out[var.y .. ":" .. var.x] = (var as {string:any}).tk as string
      end
   end
   ast_walk.walk(ast as AstNode, {
      local_type = function(node: AstNode) mark(node) end,
      global_type = function(node: AstNode) mark(node) end,
   })
   return out
end

local function is_name(t: tl.Token): boolean
   return t ~= nil and t.kind == "identifier"
end

-- Index of the token that opens the bracket closed at `close_idx`, or nil.
local function matching_open(tokens: {tl.Token}, close_idx: integer): integer
   local close = tokens[close_idx].tk
   local open = close == ")" and "(" or close == "]" and "[" or "{"
   local depth = 0
   local i = close_idx
   while i >= 1 do
      local tk = tokens[i].tk
      if tk == close then
         depth = depth + 1
      elseif tk == open then
         depth = depth - 1
         if depth == 0 then
            return i
         end
      end
      i = i - 1
   end
   return nil
end

-- Where tl recorded the type of the postfix expression whose last token is
-- tokens[last]: `a`, `a.b`, `a:m(...)`, `t[k]`, `f(x)(y)`, `(expr)` or a
-- string literal. tl records
--   * a name at the name,
--   * a field access `e.f` / `e:f` at its operator,
--   * a bracket index `e[k]` at its `[`,
--   * a parenthesized expression at its `(`,
--   * a call not at all, hence the callee plus one return level.
-- Returns nil for anything else (the receiver cannot be located reliably).
function semantic.expression_key(tokens: {tl.Token}, last: integer): semantic.ExprKey
   local t = tokens[last]
   if t == nil then
      return nil
   end
   if is_name(t) then
      local prev = tokens[last - 1]
      if prev and (prev.tk == "." or prev.tk == ":") then
         local recv = semantic.expression_key(tokens, last - 2)
         if recv == nil then
            return nil
         end
         return { y = prev.y, x = prev.x, ret_depth = 0, first = recv.first, last = last, has_call = recv.has_call }
      end
      return { y = t.y, x = t.x, ret_depth = 0, first = last, last = last, has_call = false }
   elseif t.kind == "string" then
      return { y = t.y, x = t.x, ret_depth = 0, first = last, last = last, has_call = false }
   elseif t.tk == "]" then
      local open = matching_open(tokens, last)
      if open == nil then
         return nil
      end
      local recv = semantic.expression_key(tokens, open - 1)
      if recv == nil then
         return nil
      end
      local o = tokens[open]
      return { y = o.y, x = o.x, ret_depth = 0, first = recv.first, last = last, has_call = recv.has_call }
   elseif t.tk == ")" then
      local open = matching_open(tokens, last)
      if open == nil then
         return nil
      end
      local prev = tokens[open - 1]
      local callable = prev ~= nil and (is_name(prev) or prev.tk == ")" or prev.tk == "]" or prev.kind == "string")
      if callable then
         -- `function name(` / `function(` open parameter lists, not calls
         local before = tokens[open - 2]
         if prev.kind == "keyword" or (before and before.tk == "function") then
            return nil
         end
         local callee = semantic.expression_key(tokens, open - 1)
         if callee == nil then
            return nil
         end
         return { y = callee.y, x = callee.x, ret_depth = callee.ret_depth + 1, first = callee.first, last = last, has_call = true }
      end
      if prev and prev.tk == "function" then
         return nil
      end
      local o = tokens[open]
      return { y = o.y, x = o.x, ret_depth = 0, first = open, last = last, has_call = false }
   end
   return nil
end

-- The type recorded at an expression key, following return levels.
-- Returns nil when tl recorded nothing there, or when following a return
-- reaches something unusable (an overloaded callee, a bare type variable).
function semantic.type_at_key(report: tl.TypeReport, file: string, y: integer, x: integer, ret_depth: integer): tl.TypeInfo
   local rows = report.by_pos[file]
   local row = rows and rows[y]
   local type_id = row and row[x]
   if type_id == nil then
      return nil
   end
   local ti = semantic.resolve(report, type_id)
   for _ = 1, ret_depth or 0 do
      if ti == nil or ti.t ~= tl.typecodes.FUNCTION or ti.rets == nil or ti.rets[1] == nil then
         return nil
      end
      ti = semantic.resolve(report, ti.rets[1][1])
      if ti == nil or ti.t == tl.typecodes.TYPE_VARIABLE then
         return nil
      end
   end
   return ti
end

-- Finds the call whose argument list contains the cursor: scans the lexer
-- tokens backwards from the cursor to the innermost unmatched "(" that follows
-- a callable expression. Returns that "(" token, the number of top-level
-- commas between it and the cursor (the active argument), and whether the
-- call is a method call through ":".
function semantic.enclosing_call(tokens: {tl.Token}, y: integer, x: integer): tl.Token, integer, boolean
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

-- Text of a comment without its delimiters: `--[[ … ]]` / `--[==[ … ]==]`
-- blocks or `--` / `---` line comments.
local function comment_body(text: string): string
   local level = text:match("^%-%-%[(=*)%[")
   if level then
      local body = text:sub(5 + #level, -(3 + #level))
      return (body:gsub("^[ \t]*\n?", ""):gsub("%s+$", ""))
   end
   return (text:gsub("^%-%-%-?", ""):gsub("^ ", ""):gsub("%s+$", ""))
end

-- The documentation comment of a declaration on line `y`: the contiguous
-- block of comments that sit on their own lines directly above it. tl's
-- lexer attaches comments to the following token, so they are read from the
-- first token of line `y`. A trailing comment of the previous statement, a
-- block separated by a blank line and `tls-` directives are not documentation.
-- Returns nil when there is none.
function semantic.doc_comment(tokens: {tl.Token}, y: integer): string
   local i = ast_walk.token_index_at(tokens, y, 0) + 1
   local first = tokens[i]
   if first == nil or first.y ~= y or first.comments == nil then
      return nil
   end
   local prev = tokens[i - 1]
   local parts: {string} = {}
   local expected_end = y - 1
   for k = #first.comments, 1, -1 do
      local c = first.comments[k]
      local _, newlines = c.text:gsub("\n", "")
      if c.y + newlines ~= expected_end or (prev and prev.y == c.y) or c.text:match("^%-%-%s*tls%-") then
         break
      end
      table.insert(parts, 1, comment_body(c.text))
      expected_end = c.y - 1
   end
   if #parts == 0 then
      return nil
   end
   local text = table.concat(parts, "\n")
   if text:match("^%s*$") then
      return nil
   end
   return text
end

return semantic
