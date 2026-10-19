-- Generic traversal over the tl compiler's own AST.
--
-- tl does not expose a visitor, and its Node type is abstract in the public
-- declarations, so this module describes the subset of node fields the server
-- relies on (verified against tl 0.24.8) and walks any table that carries a
-- `kind`. Type objects (which carry `typename` instead) are never entered.

local tl <const> = require("tl")

local record ast_walk
   -- The node fields used by the server. Which fields are set depends on `kind`.
   record AstNode is {AstNode}
      kind: string
      tk: string
      y: integer
      x: integer
      yend: integer
      xend: integer

      -- op
      record Operator
         op: string
         arity: integer
      end
      op: Operator
      e1: AstNode
      e2: AstNode

      -- declarations / assignments / functions
      vars: AstNode
      exps: AstNode
      args: AstNode
      body: AstNode
      name: AstNode
      value: AstNode
      var: AstNode
      fn_owner: AstNode
      is_method: boolean
      is_self: boolean
      is_lvalue: boolean
      attribute: string
      label: string

      -- `argument` nodes carry their annotation as a type object
      argtype: any
      -- `newtype` nodes carry the declared type object
      newtype: any
   end

   type Listener = function(node: AstNode, parent: AstNode)

   is_node: function(v: any): boolean
   children: function(node: AstNode): {AstNode}
   token_end: function(tok: tl.Token): integer, integer
end

local type AstNode = ast_walk.AstNode

local function is_node(v: any): boolean
   if type(v) ~= "table" then
      return false
   end
   local t = v as {string:any}
   return type(t.kind) == "string" and t.typename == nil
end
ast_walk.is_node = is_node

local function child_nodes(node: AstNode): {AstNode}
   local children: {AstNode} = {}
   for _, v in pairs(node as {any:any}) do
      if is_node(v) then
         table.insert(children, v as AstNode)
      elseif type(v) == "table" and (v as {string:any}).typename == nil then
         -- plain arrays of nodes, e.g. an `if` node's `if_blocks`
         for _, item in ipairs(v as {any}) do
            if is_node(item) then
               table.insert(children, item as AstNode)
            end
         end
      end
   end
   -- pairs() order is unspecified; visit in source order so reports are stable
   table.sort(children, function(a: AstNode, b: AstNode): boolean
      local ay, by = a.y or 0, b.y or 0
      if ay ~= by then return ay < by end
      return (a.x or 0) < (b.x or 0)
   end)
   return children
end
ast_walk.children = child_nodes

-- Visits every node under `root` in source order. `listeners[kind]` is called
-- on enter and `listeners[kind .. ":exit"]` on exit; `listeners["*"]` on every node.
function ast_walk.walk(root: AstNode, listeners: {string:ast_walk.Listener})
   local seen: {AstNode:boolean} = {}
   local any_listener = listeners["*"]

   local function visit(node: AstNode, parent: AstNode)
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

-- End position (line, exclusive column) of a token, accounting for tokens that
-- span lines (long strings and long comments).
local function token_end(tok: tl.Token): integer, integer
   local text = tok.tk
   local last_nl: integer
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

-- Index of the last token that starts at or before (y, x), or 0.
function ast_walk.token_index_at(tokens: {tl.Token}, y: integer, x: integer): integer
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

-- Start of `node`: the earliest position recorded in its subtree. (Operator
-- nodes are positioned at the operator, e.g. the "(" of a call, so the node's
-- own y/x is not necessarily where its source text begins.)
function ast_walk.node_start(node: AstNode): integer, integer
   local sy, sx = node.y, node.x
   ast_walk.walk(node, {
      ["*"] = function(n: AstNode)
         if n.y and (sy == nil or n.y < sy or (n.y == sy and n.x < sx)) then
            sy, sx = n.y, n.x
         end
      end,
   })
   return sy, sx
end

-- Returns the end of `node`: the furthest position recorded anywhere in its
-- subtree, extended to the end of the token found there. Line/exclusive column.
-- Positions at or after (limit_y, limit_x) are ignored; pass the start of the
-- next statement / the block terminator, because some nodes (e.g. a return's
-- expression list) record an end position that runs into the following token.
function ast_walk.node_end(tokens: {tl.Token}, node: AstNode, limit_y?: integer, limit_x?: integer): integer, integer
   local function within(y: integer, x: integer): boolean
      return limit_y == nil or y < limit_y or (y == limit_y and x < limit_x)
   end
   local my, mx = node.y, node.x
   ast_walk.walk(node, {
      ["*"] = function(n: AstNode)
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
      -- position past the token (e.g. inside whitespace): keep a 1-char range
      return my, mx + 1
   end
   return ey, ex
end

-- Start position of the token covering (y, x), e.g. to turn a block's recorded
-- end (which points into its `end` keyword) into a limit for node_end.
function ast_walk.token_start_at(tokens: {tl.Token}, y: integer, x: integer): integer, integer
   local tok = tokens[ast_walk.token_index_at(tokens, y, x)]
   if tok then
      return tok.y, tok.x
   end
   return y, x
end

-- Start of a statement, including a leading `local` / `global` keyword (which
-- has no node of its own: a declaration is positioned at its first variable).
function ast_walk.statement_start(tokens: {tl.Token}, stmt: AstNode): integer, integer
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

-- The token starting exactly at (y, x), if any.
function ast_walk.token_at(tokens: {tl.Token}, y: integer, x: integer): tl.Token
   local tok = tokens[ast_walk.token_index_at(tokens, y, x)]
   if tok and tok.y == y and tok.x == x then
      return tok
   end
   return nil
end

-- tl.parse_program, on a copy of the token list: when it recovers from a
-- syntax error, tl's parser inserts synthetic tokens (e.g. a missing ")")
-- into the list it is given, and callers keep using their tokens for
-- positions and context afterwards.
function ast_walk.parse_program(tokens: {tl.Token}, errs: {tl.Error}, filename: string): tl.Node
   local copy: {tl.Token} = {}
   for i, t in ipairs(tokens) do
      copy[i] = t
   end
   return (tl.parse_program(copy, errs, filename))
end

return ast_walk
