local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local string = _tl_compat and _tl_compat.string or string








local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local rule = require("teal_language_server.analysis.diagnostics.rule")
local tl = require("tl")



local implicit_any = {
   meta = {
      id = "implicit-any",
      description = "Require type annotations on function parameters",
      type = "suggestion",
      has_suggestions = true,
      requires_types = true,
      default_severity = "warn",
      default_options = {
         check_lua = false,
         ignore_pattern = "^_",
      },
   },
   create = function(ctx)
      if ctx.is_lua and not ctx.options.check_lua then
         return {}
      end
      local ignore_pattern = ctx.options.ignore_pattern
      return {
         argument = function(node)
            if node.argtype ~= nil or node.tk == "..." or node.tk == nil then
               return
            end
            if ignore_pattern and ignore_pattern ~= "" and node.tk:match(ignore_pattern) then
               return
            end


            local ti = ctx:type_at(node.y, node.x)
            if ti and ti.t ~= tl.typecodes.ANY and ti.t ~= tl.typecodes.UNKNOWN then
               return
            end
            local name_end = node.x + #node.tk
            ctx:report({
               y = node.y,
               x = node.x,
               yend = node.y,
               xend = name_end,
               message = "Parameter '" .. node.tk .. "' implicitly has an 'any' type",
               suggestions = {
                  {
                     title = "Annotate '" .. node.tk .. "' explicitly as 'any'",
                     edits = { { y = node.y, x = name_end, yend = node.y, xend = name_end, text = ": any" } },
                  },
               },
            })
         end,
      }
   end,
}

return implicit_any
