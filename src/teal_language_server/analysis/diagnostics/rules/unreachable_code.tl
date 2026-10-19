-- Reports statements that can never execute because they follow an
-- unconditional jump (`break`, `goto`, or a `do ... end` block that ends in
-- `return`/`break`/`goto`) in the same block. Lua requires `return` to be the
-- last statement of a block, so a bare `return` cannot be followed by code;
-- the `do return end` idiom can. A label ends the unreachable region because
-- a `goto` may jump to it. The compiler does not report this.

local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local rule <const> = require("teal_language_server.analysis.diagnostics.rule")

local type AstNode = ast_walk.AstNode

local function is_terminal(stmt: AstNode): boolean
   local kind = stmt.kind
   if kind == "break" or kind == "goto" or kind == "return" then
      return true
   end
   if kind == "do" and stmt.body and #stmt.body > 0 then
      return is_terminal(stmt.body[#stmt.body])
   end
   return false
end

local unreachable_code: rule.Rule = {
   meta = {
      id = "unreachable-code",
      description = "Disallow statements after break, goto, or a do-block that returns",
      type = "problem",
      default_severity = "warn",
      default_options = {},
   },
   create = function(ctx: rule.Context): {string:ast_walk.Listener}
      return {
         statements = function(block: AstNode)
            local i = 1
            local n = #block
            while i <= n do
               if is_terminal(block[i]) then
                  local first = i + 1
                  local last = i
                  local j = first
                  while j <= n and block[j].kind ~= "label" do
                     last = j
                     j = j + 1
                  end
                  if last >= first then
                     -- bound the end by the next statement, or by the block's terminator
                     local limit_y, limit_x: integer, integer
                     if last < n then
                        limit_y, limit_x = ast_walk.statement_start(ctx.tokens, block[last + 1])
                     elseif block.yend then
                        limit_y, limit_x = ast_walk.token_start_at(ctx.tokens, block.yend, block.xend)
                     end
                     local sy, sx = ast_walk.statement_start(ctx.tokens, block[first])
                     local ey, ex = ctx:node_end(block[last], limit_y, limit_x)
                     ctx:report({
                        y = sy,
                        x = sx,
                        yend = ey,
                        xend = ex,
                        message = "Unreachable code",
                        tags = { "unnecessary" },
                     })
                  end
                  i = j
               else
                  i = i + 1
               end
            end
         end,
      }
   end,
}

return unreachable_code
