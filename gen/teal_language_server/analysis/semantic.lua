local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local math = _tl_compat and _tl_compat.math or math; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table









local tl = require("tl")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")



local semantic = { VisibleSymbol = {}, ExprKey = {} }



























function semantic.resolve(report, type_id)
   local ti = type_id and report.types[type_id]
   local guard = 0
   while ti and ti.ref and guard < 100 do
      ti = report.types[ti.ref]
      guard = guard + 1
   end
   return ti
end




function semantic.visible_symbols(report, file, y, x)
   local out = {}
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
   local seen = {}
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






function semantic.type_declaration_positions(ast)
   local out = {}
   if ast == nil then
      return out
   end
   local function mark(node)
      local var = (node).var
      if var and var.y and var.x then
         out[var.y .. ":" .. var.x] = (var).tk
      end
   end
   ast_walk.walk(ast, {
      local_type = function(node) mark(node) end,
      global_type = function(node) mark(node) end,
   })
   return out
end

local function is_name(t)
   return t ~= nil and t.kind == "identifier"
end


local function matching_open(tokens, close_idx)
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










function semantic.expression_key(tokens, last)
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




function semantic.type_at_key(report, file, y, x, ret_depth)
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






function semantic.enclosing_call(tokens, y, x)

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



local function comment_body(text)
   local level = text:match("^%-%-%[(=*)%[")
   if level then
      local body = text:sub(5 + #level, -(3 + #level))
      return (body:gsub("^[ \t]*\n?", ""):gsub("%s+$", ""))
   end
   return (text:gsub("^%-%-%-?", ""):gsub("^ ", ""):gsub("%s+$", ""))
end







function semantic.doc_comment(tokens, y)
   local i = ast_walk.token_index_at(tokens, y, 0) + 1
   local first = tokens[i]
   if first == nil or first.y ~= y or first.comments == nil then
      return nil
   end
   local prev = tokens[i - 1]
   local parts = {}
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




function semantic.required_module_at(tokens, y, x)
   local i = ast_walk.token_index_at(tokens, y, x)
   local t = tokens[i]
   if t == nil or t.y ~= y or x >= t.x + #t.tk then
      return nil
   end
   local str
   if t.kind == "string" then
      local prev = tokens[i - 1]
      if prev and prev.tk == "(" then
         prev = tokens[i - 2]
      end
      if prev and prev.kind == "identifier" and prev.tk == "require" then
         str = t
      end
   elseif t.kind == "identifier" and t.tk == "require" then
      local nxt = tokens[i + 1]
      if nxt and nxt.tk == "(" then
         nxt = tokens[i + 2]
      end
      if nxt and nxt.kind == "string" then
         str = nxt
      end
   end
   if str == nil then
      return nil
   end
   return str.tk:match("^[\"'](.*)[\"']$")
end

return semantic
