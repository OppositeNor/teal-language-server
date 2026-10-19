-- Reports function parameters without a type annotation. In Teal an
-- unannotated parameter is `any` (tl does not infer parameter types from
-- context, even for callbacks), which silently disables type checking for
-- every use of the parameter. Comparable to TypeScript's noImplicitAny.
--
-- Options:
--   check_lua:      also report in .lua files (default false; they are lax anyway)
--   ignore_pattern: Lua pattern of parameter names to ignore (default "^_")

local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local rule <const> = require("teal_language_server.analysis.diagnostics.rule")
local tl <const> = require("tl")

local type AstNode = ast_walk.AstNode

local implicit_any: rule.Rule = {
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
   create = function(ctx: rule.Context): {string:ast_walk.Listener}
      if ctx.is_lua and not ctx.options.check_lua then
         return {}
      end
      local ignore_pattern = ctx.options.ignore_pattern as string
      return {
         argument = function(node: AstNode)
            if node.argtype ~= nil or node.tk == "..." or node.tk == nil then
               return
            end
            if ignore_pattern and ignore_pattern ~= "" and node.tk:match(ignore_pattern) then
               return
            end
            -- trust the compiler: only report when it actually typed the parameter
            -- as any (or unknown, which is what lax .lua checking uses)
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
