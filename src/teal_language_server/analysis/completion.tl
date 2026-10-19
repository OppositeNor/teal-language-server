-- Context-aware completion, independent of LSP types.
--
-- The pipeline follows the shape of the TypeScript language service
-- (getCompletionData: previous significant token -> context -> symbols) and of
-- rust-analyzer's CompletionContext (classify the position first, then ask
-- semantics), adapted to what tl exposes:
--
--   1. context: from the lexer tokens around the cursor (and a syntax hint
--      from tree-sitter for comment / string / type positions), decide whether
--      this is member access (`e.` / `e:`), a type position, a plain scope
--      position, or a place where nothing should be offered (a new name, a
--      number, a comment);
--   2. receiver: locate where tl recorded the type of `e` (semantic.expression_key);
--   3. candidates: members of that type, visible symbols, type names or
--      keywords -- only those that are valid there (`:` offers only methods
--      whose first parameter accepts the receiver);
--   4. ranking: explicit tiers, then the name, so the order is deterministic.
--
-- Types come from the tl type report only. When tl recorded nothing, no
-- members are invented.

local tl <const> = require("tl")
local semantic <const> = require("teal_language_server.analysis.semantic")

local record completion
   enum ContextKind
      -- `e.` / `e:` (prefix may be partially typed)
      "member"
      -- an expression or statement position: visible names and keywords
      "scope"
      -- a type annotation / cast position: type names
      "type"
      -- a key position in a table constructor `{ k = v, | }`: the fields of
      -- the constructor's record type (plus scope names)
      "constructor"
      -- the name of a new declaration: only keywords that may start one
      "declaration"
      -- inside a string literal whose expected type is known: enum values
      "literal"
      -- comment, string, number: nothing
      "none"
   end

   -- where the expected type of a string literal comes from
   enum LiteralSource
      -- an argument of the call opened at `call_paren`
      "argument"
      -- the target of `target = "…"` / `local target: T = "…"`, or the
      -- other operand of `x == "…"`
      "expression"
      -- the value of field `field` in the constructor opened at `table_open`
      "constructor_field"
   end

   enum SyntaxHint
      "code" "comment" "string" "type"
      -- the name of a declaration (a record field)
      "name"
   end

   record Context
      kind: ContextKind
      -- the identifier part typed so far (may be "")
      prefix: string
      -- start of the identifier being completed
      prefix_y: integer
      prefix_x: integer
      -- member access
      op: string
      receiver: semantic.ExprKey
      -- a member access in a type position (`m.Type`)
      in_type: boolean
      -- the text after the completed word starts with "("
      followed_by_call: boolean
      -- constructor: the "{" token, and the keys already written
      table_open: tl.Token
      present_keys: {string:boolean}
      -- literal: the string token, its content range (tl columns, end
      -- exclusive, on the token's line) and where its expected type comes from
      literal: tl.Token
      content_x: integer
      content_xend: integer
      literal_source: LiteralSource
      call_paren: integer
      arg_index: integer
      method_call: boolean
      target: semantic.ExprKey
      -- the target is assigned to: its declared type matters, and tl records
      -- the assigned value's type at it instead
      target_assigned: boolean
      field: string
   end

   enum CandidateKind
      "field" "method" "function" "variable" "type" "keyword" "enum_member" "module"
      -- a workspace module that is not required yet
      "auto_import"
   end

   record Candidate
      label: string
      kind: CandidateKind
      type_info: tl.TypeInfo
      -- smaller sorts first
      tier: integer
      -- the candidate is a method used through `:` (self is implicit)
      colon_call: boolean
      -- auto_import: the module name to require
      module: string
   end

   record ModuleRef
      name: string
      path: string
   end

   -- ranking tiers
   tiers: {string:integer}

   keywords: {string}
   declaration_keywords: {string}
   primitive_types: {string}
end

completion.tiers = {
   constructor_field = 9,
   local_value = 10,
   member_field = 10,
   member_function = 11,
   member_method = 12,
   local_type = 10,
   primitive_type = 11,
   global = 15,
   auto_import = 16,
   keyword = 17,
}

completion.keywords = {
   "and", "break", "do", "else", "elseif", "end", "enum", "false", "for", "function",
   "global", "goto", "if", "in", "interface", "local", "nil", "not", "or", "record",
   "repeat", "return", "then", "true", "type", "until", "while",
}

local completion_keywords_set: {string:boolean} = {}
for _, kw in ipairs(completion.keywords) do
   completion_keywords_set[kw] = true
end

-- keywords that can follow `local` / `global`
completion.declaration_keywords = { "enum", "function", "interface", "record", "type" }

completion.primitive_types = {
   "any", "boolean", "integer", "nil", "number", "string", "thread", "userdata",
}

local function token_end_x(t: tl.Token): integer
   return t.x + #t.tk
end

local function is_word(t: tl.Token): boolean
   return t ~= nil and (t.kind == "identifier" or t.kind == "keyword")
end

-- Index of the last real token that starts before the cursor (cy, cx), where
-- cx is the column of the character right after the cursor.
local function token_before(tokens: {tl.Token}, cy: integer, cx: integer): integer
   local lo, hi = 1, #tokens
   local found = 0
   while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local t = tokens[mid]
      if t.y < cy or (t.y == cy and t.x < cx) then
         found = mid
         lo = mid + 1
      else
         hi = mid - 1
      end
   end
   while found >= 1 and tokens[found].kind == "$EOF$" do
      found = found - 1
   end
   return found
end

-- Walks back from tokens[i] over a dotted / method function name
-- (`a.b:c`), returning the index of the token before it.
local function skip_function_name(tokens: {tl.Token}, i: integer): integer
   while i >= 1 and (tokens[i].kind == "identifier" or tokens[i].tk == "." or tokens[i].tk == ":") do
      i = i - 1
   end
   return i
end

-- Is the "(" at index `open` the start of a function definition's (or
-- function type's) parameter list?
local function opens_parameter_list(tokens: {tl.Token}, open: integer): boolean
   local i = open - 1
   -- generic parameters: function f<T>(
   if tokens[i] and tokens[i].tk == ">" then
      while i >= 1 and tokens[i].tk ~= "<" do
         i = i - 1
      end
      i = i - 1
   end
   if tokens[i] and tokens[i].tk == "function" then
      return true
   end
   local before = skip_function_name(tokens, i)
   return before < i and tokens[before] ~= nil and tokens[before].tk == "function"
end

-- Index of the innermost unmatched "(" before `i`, or nil.
local function enclosing_paren(tokens: {tl.Token}, i: integer): integer
   local depth = 0
   while i >= 1 do
      local tk = tokens[i].tk
      if tk == ")" or tk == "]" or tk == "}" then
         depth = depth + 1
      elseif tk == "(" or tk == "[" or tk == "{" then
         if depth == 0 then
            return tk == "(" and i or nil
         end
         depth = depth - 1
      elseif depth == 0 and (tk == "end" or tk == "then" or tk == "do" or tk == "local") then
         return nil
      end
      i = i - 1
   end
   return nil
end

-- Index of the innermost unmatched opening bracket at or before `i`.
local function enclosing_open(tokens: {tl.Token}, i: integer): integer
   local depth = 0
   while i >= 1 do
      local tk = tokens[i].tk
      if tk == ")" or tk == "]" or tk == "}" then
         depth = depth + 1
      elseif tk == "(" or tk == "[" or tk == "{" then
         if depth == 0 then
            return i
         end
         depth = depth - 1
      end
      i = i - 1
   end
   return nil
end

-- Keys written as `name =` at the top level of the constructor opened at
-- tokens[open].
local function written_keys(tokens: {tl.Token}, open: integer): {string:boolean}
   local keys: {string:boolean} = {}
   local depth = 0
   local i = open + 1
   while tokens[i] and tokens[i].kind ~= "$EOF$" do
      local tk = tokens[i].tk
      if tk == "(" or tk == "[" or tk == "{" then
         depth = depth + 1
      elseif tk == ")" or tk == "]" or tk == "}" then
         if depth == 0 then
            break
         end
         depth = depth - 1
      elseif depth == 0 and tokens[i].kind == "identifier" and tokens[i + 1] and tokens[i + 1].tk == "="
         and (tokens[i - 1].tk == "{" or tokens[i - 1].tk == "," or tokens[i - 1].tk == ";") then
         keys[tk] = true
      end
      i = i + 1
   end
   return keys
end

-- Is the ":" at index `colon` a type annotation (as opposed to a method
-- access)? Annotations follow a declared name (`local a:`, `local a, b:`, a
-- parameter `(a:` / `, b:`) or close a parameter list (`function f():`).
local function is_annotation_colon(tokens: {tl.Token}, colon: integer): boolean
   local prev = tokens[colon - 1]
   if prev == nil then
      return false
   end
   if prev.tk == ")" then
      -- return type of `function f(...)`
      local depth = 0
      local i = colon - 1
      while i >= 1 do
         local tk = tokens[i].tk
         if tk == ")" then
            depth = depth + 1
         elseif tk == "(" then
            depth = depth - 1
            if depth == 0 then
               return opens_parameter_list(tokens, i)
            end
         end
         i = i - 1
      end
      return false
   end
   if prev.kind ~= "identifier" then
      return false
   end
   -- `local a, b:` / `global a:`
   local i = colon - 1
   while tokens[i] and tokens[i].kind == "identifier" and tokens[i - 1] and tokens[i - 1].tk == "," do
      i = i - 2
   end
   local before = tokens[i - 1]
   if before and (before.tk == "local" or before.tk == "global") then
      return true
   end
   -- a parameter: `(a:` or `, a:` inside a parameter list
   if before and (before.tk == "(" or before.tk == ",") then
      local open = before.tk == "(" and (colon - 2) or enclosing_paren(tokens, colon - 2)
      return open ~= nil and opens_parameter_list(tokens, open)
   end
   if before and before.tk == "?" then
      -- optional parameter `?a:`
      local b2 = tokens[i - 2]
      if b2 and (b2.tk == "(" or b2.tk == ",") then
         local open = b2.tk == "(" and (i - 2) or enclosing_paren(tokens, i - 2)
         return open ~= nil and opens_parameter_list(tokens, open)
      end
   end
   return false
end

local function is_quote(c: string): boolean
   return c == "\"" or c == "'"
end

-- The string-literal context at token `idx` (which contains the cursor), or
-- nil when the cursor is not inside a short quoted string. Long strings
-- (`[[…]]`) are never enum values in practice and are not handled.
local function literal_context(tokens: {tl.Token}, idx: integer, cy: integer, cx: integer, ctx: completion.Context): boolean
   local t = tokens[idx]
   if t == nil or t.y ~= cy or not (t.kind == "string" or t.kind == "$ERR$") or not is_quote(t.tk:sub(1, 1)) then
      return false
   end
   local quote = t.tk:sub(1, 1)
   -- the first line of the token only (an unterminated string runs to EOF)
   local first_line = t.tk:match("^[^\n]*")
   local closed = t.kind == "string" and #first_line >= 2 and first_line:sub(-1) == quote
   local content_xend = closed and (t.x + #first_line - 1) or (t.x + #first_line)
   if cx <= t.x or cx > content_xend then
      return false
   end
   ctx.literal = t
   ctx.content_x = t.x + 1
   ctx.content_xend = content_xend

   local before = tokens[idx - 1]
   if before == nil then
      return true
   end
   if before.tk == "(" or before.tk == "," then
      local open = enclosing_open(tokens, idx - 1)
      if open and tokens[open].tk == "(" then
         local paren, commas, method = semantic.enclosing_call(tokens, t.y, t.x)
         if paren and paren == tokens[open] then
            ctx.literal_source = "argument"
            ctx.call_paren = open
            ctx.arg_index = commas
            ctx.method_call = method
         end
      end
   elseif before.tk == "=" then
      local name = tokens[idx - 2]
      local lead = tokens[idx - 3]
      local open = enclosing_open(tokens, idx - 1)
      if name and name.kind == "identifier" and lead and (lead.tk == "{" or lead.tk == "," or lead.tk == ";")
         and open and tokens[open].tk == "{" then
         ctx.literal_source = "constructor_field"
         ctx.table_open = tokens[open]
         ctx.field = name.tk
      else
         -- `local name[: T] =`: the declared variable (tl records its type at the name)
         local i = idx - 2
         while i >= 1 and tokens[i].y == t.y and tokens[i].tk ~= "local" and tokens[i].tk ~= "global" and tokens[i].tk ~= "=" do
            i = i - 1
         end
         if tokens[i] and (tokens[i].tk == "local" or tokens[i].tk == "global") and tokens[i + 1] and tokens[i + 1].kind == "identifier" then
            local n = tokens[i + 1]
            ctx.literal_source = "expression"
            ctx.target = { y = n.y, x = n.x, ret_depth = 0, first = i + 1, last = i + 1, has_call = false }
         else
            ctx.target = semantic.expression_key(tokens, idx - 2)
            ctx.target_assigned = true
            ctx.literal_source = ctx.target and "expression" or nil
         end
      end
   elseif before.tk == "==" or before.tk == "~=" then
      ctx.target = semantic.expression_key(tokens, idx - 2)
      ctx.literal_source = ctx.target and "expression" or nil
   end
   return true
end

-- Classifies the cursor position. `cy`/`cx` are tl coordinates of the
-- character after the cursor; `syntax` is the tree-sitter hint for that spot;
-- `line_after` is the rest of the line after the cursor.
function completion.context(tokens: {tl.Token}, cy: integer, cx: integer, syntax: completion.SyntaxHint, line_after: string): completion.Context
   local ctx: completion.Context = { kind = "scope", prefix = "", prefix_y = cy, prefix_x = cx }
   if syntax == "comment" or syntax == "name" then
      ctx.kind = "none"
      return ctx
   end

   local idx = token_before(tokens, cy, cx)
   if literal_context(tokens, idx, cy, cx, ctx) then
      ctx.kind = ctx.literal_source and "literal" or "none"
      return ctx
   end
   if syntax == "string" then
      ctx.kind = "none"
      return ctx
   end
   local t = tokens[idx]
   if t and t.y == cy and token_end_x(t) >= cx then
      -- the cursor is inside or at the end of token t
      if is_word(t) then
         ctx.prefix = t.tk:sub(1, cx - t.x)
         ctx.prefix_y, ctx.prefix_x = t.y, t.x
         idx = idx - 1
      elseif t.kind == "number" or t.kind == "integer" or t.kind == "string" or t.kind == "$ERR$" then
         ctx.kind = "none"
         return ctx
      end
   end

   local rest = (line_after or ""):gsub("^[%w_]*", "")
   ctx.followed_by_call = rest:match("^%s*%(") ~= nil

   local before = tokens[idx]
   if before and (before.tk == "." or before.tk == ":") then
      if before.tk == ":" and (syntax == "type" or is_annotation_colon(tokens, idx)) then
         ctx.kind = "type"
         return ctx
      end
      ctx.op = before.tk
      ctx.kind = "member"
      -- a qualified type name `m.T`: a dotted chain after an annotation
      -- colon, `as` or `is`
      if before.tk == "." then
         local first = idx - 1
         while tokens[first] and tokens[first].kind == "identifier"
            and tokens[first - 1] and tokens[first - 1].tk == "." and tokens[first - 2] and tokens[first - 2].kind == "identifier" do
            first = first - 2
         end
         local lead = tokens[first - 1]
         if tokens[first] and tokens[first].kind == "identifier" and (syntax == "type" or (lead and
            ((lead.tk == ":" and is_annotation_colon(tokens, first - 1)) or lead.tk == "as" or lead.tk == "is"))) then
            ctx.in_type = true
            ctx.receiver = { y = tokens[first].y, x = tokens[first].x, ret_depth = 0, first = first, last = idx - 1, has_call = false }
            return ctx
         end
      end
      ctx.receiver = semantic.expression_key(tokens, idx - 1)
      if ctx.receiver == nil then
         ctx.kind = "none"
      end
      return ctx
   end

   if before and (before.tk == "as" or before.tk == "is") then
      ctx.kind = "type"
      return ctx
   end

   if before and (before.tk == "local" or before.tk == "global") then
      ctx.kind = "declaration"
      return ctx
   end

   if before and (before.tk == "function" or before.tk == "for" or before.tk == "goto" or before.tk == "::"
      or before.tk == "record" or before.tk == "enum" or before.tk == "interface"
      or (before.tk == "type" and tokens[idx - 1] and (tokens[idx - 1].tk == "local" or tokens[idx - 1].tk == "global"))) then
      -- `function name` declares a name, unless it extends an existing one
      -- (`function M.f`), which is member access handled above
      ctx.kind = "none"
      return ctx
   end

   -- `local a, b|` (more names being declared)
   if before and before.tk == "," then
      local i = idx - 1
      while tokens[i] and tokens[i].kind == "identifier" and tokens[i - 1] and tokens[i - 1].tk == "," do
         i = i - 2
      end
      if tokens[i] and tokens[i].kind == "identifier" and tokens[i - 1] and (tokens[i - 1].tk == "local" or tokens[i - 1].tk == "for") then
         ctx.kind = "none"
         return ctx
      end
   end

   if syntax == "type" then
      ctx.kind = "type"
      return ctx
   end

   if before and (before.tk == "{" or before.tk == "," or before.tk == ";") then
      local open = enclosing_open(tokens, idx)
      if open and tokens[open].tk == "{" then
         ctx.kind = "constructor"
         ctx.table_open = tokens[open]
         ctx.present_keys = written_keys(tokens, open)
      end
   end
   return ctx
end

local function is_callable(ti: tl.TypeInfo): boolean
   return ti ~= nil and (ti.t == tl.typecodes.FUNCTION or ti.t == tl.typecodes.POLY)
end

local function is_type_value(ti: tl.TypeInfo): boolean
   if ti == nil then
      return false
   end
   local t = ti.t
   return t == tl.typecodes.RECORD or t == tl.typecodes.ENUM or t == tl.typecodes.INTERFACE
end

-- Can `fn` be called as `receiver:fn(...)`? Its first parameter must be
-- `self` or the receiver's own (nominal) type.
local function is_self_method(report: tl.TypeReport, fn: tl.TypeInfo, receiver: tl.TypeInfo, receiver_is_string: boolean): boolean
   if fn == nil or fn.t ~= tl.typecodes.FUNCTION or not fn.args or #fn.args < 1 then
      return false
   end
   local first = semantic.resolve(report, fn.args[1][1])
   if first == nil then
      return false
   end
   if first.t == tl.typecodes.SELF then
      return true
   end
   if receiver_is_string then
      return first.t == tl.typecodes.STRING
   end
   if first == receiver then
      return true
   end
   -- generic or re-instantiated records are distinct type objects with the
   -- same name, and tl leaves some `self: R` parameters as a nominal without
   -- a resolved reference; those are matched by the type's name
   return (first.t == tl.typecodes.RECORD or first.t == tl.typecodes.INTERFACE or first.t == tl.typecodes.NOMINAL)
      and first.str ~= nil and first.str == receiver.str
end

local function any_self_method(report: tl.TypeReport, ti: tl.TypeInfo, receiver: tl.TypeInfo, receiver_is_string: boolean): boolean
   if ti.t == tl.typecodes.POLY then
      for _, ref in ipairs(ti.types or {}) do
         if is_self_method(report, semantic.resolve(report, ref), receiver, receiver_is_string) then
            return true
         end
      end
      return false
   end
   return is_self_method(report, ti, receiver, receiver_is_string)
end

-- Members of `receiver` valid after `op`.
function completion.member_candidates(report: tl.TypeReport, receiver: tl.TypeInfo, op: string, in_type: boolean): {completion.Candidate}
   local out: {completion.Candidate} = {}
   if receiver == nil then
      return out
   end
   local is_string = receiver.t == tl.typecodes.STRING or receiver.t == tl.typecodes.ENUM
   local container = receiver
   if is_string and not in_type then
      container = semantic.resolve(report, report.globals["string"])
   end
   if container == nil then
      return out
   end

   if container.fields then
      for name, id in pairs(container.fields) do
         local ti = semantic.resolve(report, id)
         if ti then
            if in_type then
               if is_type_value(ti) then
                  table.insert(out, { label = name, kind = "type", type_info = ti, tier = completion.tiers.local_type })
               end
            elseif op == ":" then
               if any_self_method(report, ti, receiver, is_string) then
                  table.insert(out, { label = name, kind = "method", type_info = ti, tier = completion.tiers.member_field, colon_call = true })
               end
            elseif is_callable(ti) then
               if any_self_method(report, ti, receiver, is_string) then
                  table.insert(out, { label = name, kind = "method", type_info = ti, tier = completion.tiers.member_method })
               else
                  table.insert(out, { label = name, kind = "function", type_info = ti, tier = completion.tiers.member_function })
               end
            else
               table.insert(out, { label = name, kind = "field", type_info = ti, tier = completion.tiers.member_field })
            end
         end
      end
   elseif receiver.keys and op == "." and not in_type then
      -- `t.k` on a map with enum keys
      local keys = semantic.resolve(report, receiver.keys)
      if keys and keys.enums then
         local values = semantic.resolve(report, receiver.values)
         for _, v in ipairs(keys.enums) do
            table.insert(out, { label = v, kind = "enum_member", type_info = values, tier = completion.tiers.member_field })
         end
      end
   end
   return out
end

-- Visible names (locals innermost first, then globals) for a value position.
-- `type_positions` marks names declared as types.
function completion.scope_candidates(report: tl.TypeReport, file: string, y: integer, x: integer, type_positions: {string:string}, prefix_y: integer, prefix_x: integer): {completion.Candidate}
   local out: {completion.Candidate} = {}
   local seen: {string:boolean} = {}
   for _, s in ipairs(semantic.visible_symbols(report, file, y, x)) do
      -- skip internal names and the very identifier being typed
      if s.name:sub(1, 1) ~= "@" and not (s.y == prefix_y and s.x == prefix_x) then
         seen[s.name] = true
         local ti = semantic.resolve(report, s.type_id)
         local kind: completion.CandidateKind = "variable"
         if type_positions[s.y .. ":" .. s.x] then
            kind = "type"
         elseif is_callable(ti) then
            kind = "function"
         end
         table.insert(out, { label = s.name, kind = kind, type_info = ti, tier = completion.tiers.local_value })
      end
   end
   for name, id in pairs(report.globals) do
      if not seen[name] and name:sub(1, 1) ~= "@" then
         local ti = semantic.resolve(report, id)
         local kind: completion.CandidateKind = is_callable(ti) and "function" or "variable"
         table.insert(out, { label = name, kind = kind, type_info = ti, tier = completion.tiers.global })
      end
   end
   return out
end

-- Type names for a type position: types declared in visible scopes, the
-- primitive types and global types.
function completion.type_candidates(report: tl.TypeReport, file: string, y: integer, x: integer, type_positions: {string:string}): {completion.Candidate}
   local out: {completion.Candidate} = {}
   local seen: {string:boolean} = {}
   for _, s in ipairs(semantic.visible_symbols(report, file, y, x)) do
      if type_positions[s.y .. ":" .. s.x] then
         seen[s.name] = true
         table.insert(out, { label = s.name, kind = "type", type_info = semantic.resolve(report, s.type_id), tier = completion.tiers.local_type })
      elseif not seen[s.name] then
         -- a value shadows an outer type of the same name, but a module
         -- table (a record value) can still qualify types: `mod.Type`
         seen[s.name] = true
         local ti = semantic.resolve(report, s.type_id)
         if ti and ti.fields then
            for _, id in pairs(ti.fields) do
               if is_type_value(semantic.resolve(report, id)) then
                  table.insert(out, { label = s.name, kind = "module", type_info = ti, tier = completion.tiers.global })
                  break
               end
            end
         end
      end
   end
   for _, name in ipairs(completion.primitive_types) do
      if not seen[name] then
         seen[name] = true
         table.insert(out, { label = name, kind = "keyword", tier = completion.tiers.primitive_type })
      end
   end
   for name, id in pairs(report.globals) do
      if not seen[name] then
         local ti = semantic.resolve(report, id)
         -- global record values (string, math, ...) are not types
         if ti and (ti.t == tl.typecodes.ENUM or ti.t == tl.typecodes.INTERFACE) then
            table.insert(out, { label = name, kind = "type", type_info = ti, tier = completion.tiers.global })
         end
      end
   end
   return out
end

-- Fields of the record a table constructor builds, minus the keys already
-- written. `table_type` is what tl recorded at the constructor's "{".
function completion.constructor_candidates(report: tl.TypeReport, table_type: tl.TypeInfo, present: {string:boolean}): {completion.Candidate}
   local out: {completion.Candidate} = {}
   if table_type == nil or table_type.t ~= tl.typecodes.RECORD or table_type.fields == nil then
      return out
   end
   for name, id in pairs(table_type.fields) do
      local ti = semantic.resolve(report, id)
      -- nested type declarations are not keys of a value
      if not present[name] and ti and not is_type_value(ti) then
         -- methods are normally implemented on the type, not per value
         local tier = any_self_method(report, ti, table_type, false) and completion.tiers.member_method or completion.tiers.constructor_field
         table.insert(out, { label = name, kind = "field", type_info = ti, tier = tier })
      end
   end
   return out
end

-- The string values a value of type `ti` can take: an enum's values, or
-- those of every enum in a union.
function completion.enum_values(report: tl.TypeReport, ti: tl.TypeInfo): {string}
   local out: {string} = {}
   local seen: {string:boolean} = {}
   local function add(t: tl.TypeInfo, depth: integer)
      if t == nil or depth > 8 then
         return
      end
      if t.t == tl.typecodes.ENUM and t.enums then
         for _, v in ipairs(t.enums) do
            if not seen[v] then
               seen[v] = true
               table.insert(out, v)
            end
         end
      elseif t.t == tl.typecodes.UNION and t.types then
         for _, id in ipairs(t.types) do
            add(semantic.resolve(report, id), depth + 1)
         end
      end
   end
   add(ti, 0)
   table.sort(out)
   return out
end

-- Type of parameter `index` (1-based) of a function, POLY overloads
-- included; a vararg function repeats its last parameter.
function completion.parameter_types(report: tl.TypeReport, fn: tl.TypeInfo, index: integer): {tl.TypeInfo}
   local out: {tl.TypeInfo} = {}
   if fn == nil then
      return out
   end
   local candidates: {tl.TypeInfo} = { fn }
   if fn.t == tl.typecodes.POLY then
      candidates = {}
      for _, id in ipairs(fn.types or {}) do
         table.insert(candidates, semantic.resolve(report, id))
      end
   end
   for _, f in ipairs(candidates) do
      if f and f.t == tl.typecodes.FUNCTION and f.args then
         local arg = f.args[index] or (f.vararg and f.args[#f.args])
         if arg then
            table.insert(out, semantic.resolve(report, arg[1]))
         end
      end
   end
   return out
end

-- Modules already required in the file: `require("m")` / `require "m"`.
function completion.required_modules(tokens: {tl.Token}): {string:boolean}
   local out: {string:boolean} = {}
   for i, t in ipairs(tokens) do
      if t.tk == "require" and t.kind == "identifier" then
         local nxt = tokens[i + 1]
         if nxt and nxt.tk == "(" then
            nxt = tokens[i + 2]
         end
         if nxt and nxt.kind == "string" then
            local name = nxt.tk:match("^[\"'](.*)[\"']$")
            if name then
               out[name] = true
            end
         end
      end
   end
   return out
end

-- The local name an auto-import binds a module to: its last component
-- (`util.strings` -> `strings`), or nil if that is not an identifier.
function completion.import_name(module: string): string
   local last = module:match("([^%.]+)$")
   if last and last:match("^[%a_][%w_]*$") and not completion_keywords_set[last] then
      return last
   end
   return nil
end

-- Workspace modules offered for auto-import at a scope position: not the
-- current file, not required yet, and whose local name is not already
-- visible (`visible` holds the names in scope and the globals) and starts
-- with the typed prefix's first letter (case-insensitive). An empty prefix
-- offers none, as the list would be the whole workspace.
function completion.auto_import_candidates(modules: {completion.ModuleRef}, current_path: string, required: {string:boolean}, visible: {string:boolean}, prefix: string): {completion.Candidate}
   local out: {completion.Candidate} = {}
   if prefix == nil or prefix == "" then
      return out
   end
   local first = prefix:sub(1, 1):lower()
   local seen: {string:boolean} = {}
   for _, m in ipairs(modules) do
      local name = completion.import_name(m.name)
      if name and m.path ~= current_path and not required[m.name] and not visible[name] and not seen[name]
         and name:sub(1, 1):lower() == first then
         seen[name] = true
         table.insert(out, { label = name, kind = "auto_import", module = m.name, tier = completion.tiers.auto_import })
      end
   end
   return out
end

-- Line (1-based) before which an auto-import's `local x = require(...)` is
-- inserted: after the last leading `local x = require(...)` statement, else
-- before the first statement (after a leading comment block, which stays
-- the file's header). Returns 1 for an empty file.
function completion.import_insertion_line(tokens: {tl.Token}): integer
   local i = 1
   local after: integer
   while tokens[i] and tokens[i].tk == "local" and tokens[i + 1] and tokens[i + 1].kind == "identifier"
      and tokens[i + 2] and tokens[i + 2].tk == "=" and tokens[i + 3] and tokens[i + 3].tk == "require" do
      -- skip `require(...)` / `require "..."`, plus a trailing `.field` chain
      local j = i + 4
      if tokens[j] and tokens[j].tk == "(" then
         while tokens[j] and tokens[j].tk ~= ")" do j = j + 1 end
         j = j + 1
      else
         j = j + 1
      end
      while tokens[j] and tokens[j].tk == "." and tokens[j + 1] and tokens[j + 1].kind == "identifier" do
         j = j + 2
      end
      after = tokens[j - 1].y
      i = j
   end
   if after then
      return after + 1
   end
   local first = tokens[1]
   if first == nil or first.kind == "$EOF$" then
      return 1
   end
   -- a leading comment block attached to the first statement is a header
   if first.comments and #first.comments > 0 then
      local c = first.comments[#first.comments]
      local _, newlines = c.text:gsub("\n", "")
      return math.min(first.y, c.y + newlines + 1)
   end
   return first.y
end

function completion.keyword_candidates(words: {string}): {completion.Candidate}
   local out: {completion.Candidate} = {}
   for _, kw in ipairs(words) do
      table.insert(out, { label = kw, kind = "keyword", tier = completion.tiers.keyword })
   end
   return out
end

-- Orders candidates by tier, then name, and keeps the first of equal labels.
-- No prefix filtering: clients filter (fuzzily) on the word being typed.
function completion.sort(cands: {completion.Candidate}): {completion.Candidate}
   table.sort(cands, function(a: completion.Candidate, b: completion.Candidate): boolean
      if a.tier ~= b.tier then
         return a.tier < b.tier
      end
      return a.label < b.label
   end)
   local out: {completion.Candidate} = {}
   local seen: {string:boolean} = {}
   for _, c in ipairs(cands) do
      if not seen[c.label] then
         seen[c.label] = true
         table.insert(out, c)
      end
   end
   return out
end

return completion
