local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table






local tl = require("tl")

local ast_walk = { AstNode = { Operator = {} } }
















































local function is_node(v)
   if type(v) ~= "table" then
      return false
   end
   local t = v
   return type(t.kind) == "string" and t.typename == nil
end
ast_walk.is_node = is_node

local function child_nodes(node)
   local children = {}
   for _, v in pairs(node) do
      if is_node(v) then
         table.insert(children, v)
      elseif type(v) == "table" and (v).typename == nil then

         for _, item in ipairs(v) do
            if is_node(item) then
               table.insert(children, item)
            end
         end
      end
   end

   table.sort(children, function(a, b)
      local ay, by = a.y or 0, b.y or 0
      if ay ~= by then return ay < by end
      return (a.x or 0) < (b.x or 0)
   end)
   return children
end
ast_walk.children = child_nodes



function ast_walk.walk(root, listeners)
   local seen = {}
   local any_listener = listeners["*"]

   local function visit(node, parent)
      if seen[node] then
         return
      end
      seen[node] = true

      if any_listener then any_listener(node, parent) end
      local enter = listeners[node.kind]
      if enter then enter(node, parent) end

      for _, child in ipairs(child_nodes(node)) do
         visit(child, node)
      end

      local exit = listeners[node.kind .. ":exit"]
      if exit then exit(node, parent) end
   end

   if root then
      visit(root, nil)
   end
end



local function token_end(tok)
   local text = tok.tk
   local last_nl
   local lines = 0
   local i = 1
   while true do
      local nl = text:find("\n", i, true)
      if not nl then break end
      lines = lines + 1
      last_nl = nl
      i = nl + 1
   end
   if lines == 0 then
      return tok.y, tok.x + #text
   end
   return tok.y + lines, #text - last_nl + 1
end
ast_walk.token_end = token_end


function ast_walk.token_index_at(tokens, y, x)
   local lo, hi = 1, #tokens
   local found = 0
   while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local t = tokens[mid]
      if t.y < y or (t.y == y and t.x <= x) then
         found = mid
         lo = mid + 1
      else
         hi = mid - 1
      end
   end
   return found
end




function ast_walk.node_start(node)
   local sy, sx = node.y, node.x
   ast_walk.walk(node, {
      ["*"] = function(n)
         if n.y and (sy == nil or n.y < sy or (n.y == sy and n.x < sx)) then
            sy, sx = n.y, n.x
         end
      end,
   })
   return sy, sx
end






function ast_walk.node_end(tokens, node, limit_y, limit_x)
   local function within(y, x)
      return limit_y == nil or y < limit_y or (y == limit_y and x < limit_x)
   end
   local my, mx = node.y, node.x
   ast_walk.walk(node, {
      ["*"] = function(n)
         if n.y and within(n.y, n.x) and (n.y > my or (n.y == my and n.x > mx)) then
            my, mx = n.y, n.x
         end
         if n.yend and n.xend and within(n.yend, n.xend) and (n.yend > my or (n.yend == my and n.xend > mx)) then
            my, mx = n.yend, n.xend
         end
      end,
   })
   local idx = ast_walk.token_index_at(tokens, my, mx)
   local tok = tokens[idx]
   if tok == nil or tok.kind == "$EOF$" then
      return my, mx + 1
   end
   local ey, ex = token_end(tok)
   if ey < my or (ey == my and ex <= mx) then

      return my, mx + 1
   end
   return ey, ex
end



function ast_walk.token_start_at(tokens, y, x)
   local tok = tokens[ast_walk.token_index_at(tokens, y, x)]
   if tok then
      return tok.y, tok.x
   end
   return y, x
end



function ast_walk.statement_start(tokens, stmt)
   local sy, sx = ast_walk.node_start(stmt)
   local idx = ast_walk.token_index_at(tokens, sy, sx)
   local tok = tokens[idx]
   if tok and tok.y == sy and tok.x == sx then
      local prev = tokens[idx - 1]
      if prev and (prev.tk == "local" or prev.tk == "global") then
         return prev.y, prev.x
      end
   end
   return sy, sx
end


function ast_walk.token_at(tokens, y, x)
   local tok = tokens[ast_walk.token_index_at(tokens, y, x)]
   if tok and tok.y == y and tok.x == x then
      return tok
   end
   return nil
end





function ast_walk.parse_program(tokens, errs, filename)
   local copy = {}
   for i, t in ipairs(tokens) do
      copy[i] = t
   end
   return (tl.parse_program(copy, errs, filename))
end

return ast_walk
