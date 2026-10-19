-- Quick fixes for problems reported by the tl compiler itself.
--
-- Only edits whose effect is fully determined by the AST are offered:
--   * unused `local x = require("m")` (single variable, single require call):
--     "Remove unused import" -- a safe `fix`, included in fix-all. Like
--     TypeScript's unused-import removal, the require call's side effects are
--     assumed irrelevant for a module bound to a name.
--   * any other unused local, local function, local type or argument:
--     "Prefix with '_'" -- a `suggestion` only, since it silences rather than
--     fixes the warning (tl ignores names starting with '_').

local tl <const> = require("tl")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local problem <const> = require("teal_language_server.analysis.diagnostics.problem")
local position <const> = require("teal_language_server.util.position")

local type AstNode = ast_walk.AstNode

local record compiler_fixes
end

local local_decl_kinds: {string:boolean} = {
   local_declaration = true,
   local_type = true,
   local_function = true,
   local_macroexp = true,
}

local function is_require_call(exp: AstNode): boolean
   return exp ~= nil
      and exp.kind == "op"
      and exp.op ~= nil and exp.op.op == "@funcall"
      and exp.e1 ~= nil and exp.e1.kind == "variable" and exp.e1.tk == "require"
end

local function trim(s: string): string
   return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Edit deleting a statement; whole lines are removed when the statement is the
-- only thing on them, so no blank line is left behind.
local function statement_deletion(lines: {string}, tokens: {tl.Token}, stmt: AstNode): problem.TextEdit
   local sy, sx = ast_walk.statement_start(tokens, stmt)
   local ey, ex = ast_walk.node_end(tokens, stmt)
   local first_line = lines[sy] or ""
   local last_line = lines[ey] or ""
   local before = first_line:sub(1, sx - 1)
   local after = last_line:sub(ex)
   if trim(before) == "" and (trim(after) == "" or trim(after) == ";") then
      if ey < #lines then
         return { y = sy, x = 1, yend = ey + 1, xend = 1, text = "" }
      elseif sy > 1 then
         -- last line of the file: remove the preceding line break instead
         return { y = sy - 1, x = #lines[sy - 1] + 1, yend = ey, xend = #last_line + 1, text = "" }
      end
      return { y = sy, x = 1, yend = ey, xend = #last_line + 1, text = "" }
   end
   return { y = sy, x = sx, yend = ey, xend = ex, text = "" }
end

function compiler_fixes.attach(content: string, tokens: {tl.Token}, ast: AstNode, problems: {problem.Problem})
   local wanted: {string:problem.Problem} = {}
   local any = false
   for _, p in ipairs(problems) do
      if p.rule_id == "tl/unused" then
         wanted[p.y .. ":" .. p.x] = p
         any = true
      end
   end
   if not any or ast == nil then
      return
   end

   local lines = position.split_lines(content or "")

   ast_walk.walk(ast, {
      ["*"] = function(node: AstNode, parent: AstNode)
         if node.y == nil or node.x == nil then
            return
         end
         local p = wanted[node.y .. ":" .. node.x]
         if p == nil then
            return
         end

         -- the warning points at the declared name, except for local functions
         -- (reported at the `local` keyword) and declaration nodes that share
         -- their first variable's position
         local name_node: AstNode
         if node.kind == "argument" then
            name_node = node
         elseif node.kind == "local_function" then
            name_node = node.name
         elseif node.kind == "identifier" and parent and (parent.kind == "variable_list" or local_decl_kinds[parent.kind]) then
            name_node = node
         elseif local_decl_kinds[node.kind] and node.vars and #node.vars == 1 then
            name_node = node.vars[1]
         end
         if name_node == nil or name_node.tk == nil or name_node.tk:sub(1, 1) == "_" then
            return
         end
         wanted[node.y .. ":" .. node.x] = nil

         p.suggestions = p.suggestions or {}
         table.insert(p.suggestions, {
            title = "Prefix '" .. name_node.tk .. "' with an underscore",
            edits = { { y = name_node.y, x = name_node.x, yend = name_node.y, xend = name_node.x, text = "_" } },
         })
      end,
      local_declaration = function(node: AstNode)
         -- unused import: `local x = require("m")`
         if node.vars == nil or #node.vars ~= 1 or node.exps == nil or #node.exps ~= 1 then
            return
         end
         local var = node.vars[1]
         if var.y == nil or var.x == nil then
            return
         end
         local key = var.y .. ":" .. var.x
         local p: problem.Problem
         for _, cand in ipairs(problems) do
            if cand.rule_id == "tl/unused" and cand.y .. ":" .. cand.x == key then
               p = cand
            end
         end
         if p == nil or not is_require_call(node.exps[1]) then
            return
         end
         p.fix = {
            title = "Remove unused import '" .. tostring(var.tk) .. "'",
            edits = { statement_deletion(lines, tokens, node) },
         }
      end,
   })
end

return compiler_fixes
