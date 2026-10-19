






local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local rule = require("teal_language_server.analysis.diagnostics.rule")



local function is_terminal(stmt)
   local kind = stmt.kind
   if kind == "break" or kind == "goto" or kind == "return" then
      return true
   end
   if kind == "do" and stmt.body and #stmt.body > 0 then
      return is_terminal(stmt.body[#stmt.body])
   end
   return false
end

local unreachable_code = {
   meta = {
      id = "unreachable-code",
      description = "Disallow statements after break, goto, or a do-block that returns",
      type = "problem",
      default_severity = "warn",
      default_options = {},
   },
   create = function(ctx)
      return {
         statements = function(block)
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

                     local limit_y, limit_x
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
