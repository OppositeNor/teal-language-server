local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table




















local tl = require("tl")
local semantic = require("teal_language_server.analysis.semantic")

local completion = { Context = {}, Candidate = {} }































































completion.tiers = {
   constructor_field = 9,
   local_value = 10,
   member_field = 10,
   member_function = 11,
   member_method = 12,
   local_type = 10,
   primitive_type = 11,
   global = 15,
   keyword = 17,
}

completion.keywords = {
   "and", "break", "do", "else", "elseif", "end", "enum", "false", "for", "function",
   "global", "goto", "if", "in", "interface", "local", "nil", "not", "or", "record",
   "repeat", "return", "then", "true", "type", "until", "while",
}


completion.declaration_keywords = { "enum", "function", "interface", "record", "type" }

completion.primitive_types = {
   "any", "boolean", "integer", "nil", "number", "string", "thread", "userdata",
}

local function token_end_x(t)
   return t.x + #t.tk
end

local function is_word(t)
   return t ~= nil and (t.kind == "identifier" or t.kind == "keyword")
end



local function token_before(tokens, cy, cx)
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



local function skip_function_name(tokens, i)
   while i >= 1 and (tokens[i].kind == "identifier" or tokens[i].tk == "." or tokens[i].tk == ":") do
      i = i - 1
   end
   return i
end



local function opens_parameter_list(tokens, open)
   local i = open - 1

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


local function enclosing_paren(tokens, i)
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


local function enclosing_open(tokens, i)
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



local function written_keys(tokens, open)
   local keys = {}
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
      elseif depth == 0 and tokens[i].kind == "identifier" and tokens[i + 1] and tokens[i + 1].tk == "=" and
         (tokens[i - 1].tk == "{" or tokens[i - 1].tk == "," or tokens[i - 1].tk == ";") then
         keys[tk] = true
      end
      i = i + 1
   end
   return keys
end




local function is_annotation_colon(tokens, colon)
   local prev = tokens[colon - 1]
   if prev == nil then
      return false
   end
   if prev.tk == ")" then

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

   local i = colon - 1
   while tokens[i] and tokens[i].kind == "identifier" and tokens[i - 1] and tokens[i - 1].tk == "," do
      i = i - 2
   end
   local before = tokens[i - 1]
   if before and (before.tk == "local" or before.tk == "global") then
      return true
   end

   if before and (before.tk == "(" or before.tk == ",") then
      local open = before.tk == "(" and (colon - 2) or enclosing_paren(tokens, colon - 2)
      return open ~= nil and opens_parameter_list(tokens, open)
   end
   if before and before.tk == "?" then

      local b2 = tokens[i - 2]
      if b2 and (b2.tk == "(" or b2.tk == ",") then
         local open = b2.tk == "(" and (i - 2) or enclosing_paren(tokens, i - 2)
         return open ~= nil and opens_parameter_list(tokens, open)
      end
   end
   return false
end




function completion.context(tokens, cy, cx, syntax, line_after)
   local ctx = { kind = "scope", prefix = "", prefix_y = cy, prefix_x = cx }
   if syntax == "comment" or syntax == "string" or syntax == "name" then
      ctx.kind = "none"
      return ctx
   end

   local idx = token_before(tokens, cy, cx)
   local t = tokens[idx]
   if t and t.y == cy and token_end_x(t) >= cx then

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


      if before.tk == "." then
         local first = idx - 1
         while tokens[first] and tokens[first].kind == "identifier" and
            tokens[first - 1] and tokens[first - 1].tk == "." and tokens[first - 2] and tokens[first - 2].kind == "identifier" do
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

   if before and (before.tk == "function" or before.tk == "for" or before.tk == "goto" or before.tk == "::" or
      before.tk == "record" or before.tk == "enum" or before.tk == "interface" or
      (before.tk == "type" and tokens[idx - 1] and (tokens[idx - 1].tk == "local" or tokens[idx - 1].tk == "global"))) then


      ctx.kind = "none"
      return ctx
   end


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

local function is_callable(ti)
   return ti ~= nil and (ti.t == tl.typecodes.FUNCTION or ti.t == tl.typecodes.POLY)
end

local function is_type_value(ti)
   if ti == nil then
      return false
   end
   local t = ti.t
   return t == tl.typecodes.RECORD or t == tl.typecodes.ENUM or t == tl.typecodes.INTERFACE
end



local function is_self_method(report, fn, receiver, receiver_is_string)
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



   return (first.t == tl.typecodes.RECORD or first.t == tl.typecodes.INTERFACE or first.t == tl.typecodes.NOMINAL) and
   first.str ~= nil and first.str == receiver.str
end

local function any_self_method(report, ti, receiver, receiver_is_string)
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


function completion.member_candidates(report, receiver, op, in_type)
   local out = {}
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



function completion.scope_candidates(report, file, y, x, type_positions, prefix_y, prefix_x)
   local out = {}
   local seen = {}
   for _, s in ipairs(semantic.visible_symbols(report, file, y, x)) do

      if s.name:sub(1, 1) ~= "@" and not (s.y == prefix_y and s.x == prefix_x) then
         seen[s.name] = true
         local ti = semantic.resolve(report, s.type_id)
         local kind = "variable"
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
         local kind = is_callable(ti) and "function" or "variable"
         table.insert(out, { label = name, kind = kind, type_info = ti, tier = completion.tiers.global })
      end
   end
   return out
end



function completion.type_candidates(report, file, y, x, type_positions)
   local out = {}
   local seen = {}
   for _, s in ipairs(semantic.visible_symbols(report, file, y, x)) do
      if type_positions[s.y .. ":" .. s.x] then
         seen[s.name] = true
         table.insert(out, { label = s.name, kind = "type", type_info = semantic.resolve(report, s.type_id), tier = completion.tiers.local_type })
      elseif not seen[s.name] then


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

         if ti and (ti.t == tl.typecodes.ENUM or ti.t == tl.typecodes.INTERFACE) then
            table.insert(out, { label = name, kind = "type", type_info = ti, tier = completion.tiers.global })
         end
      end
   end
   return out
end



function completion.constructor_candidates(report, table_type, present)
   local out = {}
   if table_type == nil or table_type.t ~= tl.typecodes.RECORD or table_type.fields == nil then
      return out
   end
   for name, id in pairs(table_type.fields) do
      local ti = semantic.resolve(report, id)

      if not present[name] and ti and not is_type_value(ti) then

         local tier = any_self_method(report, ti, table_type, false) and completion.tiers.member_method or completion.tiers.constructor_field
         table.insert(out, { label = name, kind = "field", type_info = ti, tier = tier })
      end
   end
   return out
end

function completion.keyword_candidates(words)
   local out = {}
   for _, kw in ipairs(words) do
      table.insert(out, { label = kw, kind = "keyword", tier = completion.tiers.keyword })
   end
   return out
end



function completion.sort(cands)
   table.sort(cands, function(a, b)
      if a.tier ~= b.tier then
         return a.tier < b.tier
      end
      return a.label < b.label
   end)
   local out = {}
   local seen = {}
   for _, c in ipairs(cands) do
      if not seen[c.label] then
         seen[c.label] = true
         table.insert(out, c)
      end
   end
   return out
end

return completion
