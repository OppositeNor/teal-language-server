-- Lint rule contract, modeled on ESLint's rule objects (`meta` + `create`).
--
-- A rule's `create` receives a Context and returns listeners keyed by tl AST
-- node kind (see ast_walk). Rules report through `ctx:report`; the engine fills
-- in rule id and configured severity, applies suppression directives and sorts.

local tl <const> = require("tl")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local problem <const> = require("teal_language_server.analysis.diagnostics.problem")

local record rule
   enum RuleType
      -- likely bug
      "problem"
      -- better way of doing something; not a bug
      "suggestion"
   end

   record Meta
      id: string
      description: string
      type: RuleType
      -- reports carry a safe `fix`
      fixable: boolean
      -- reports carry `suggestions`
      has_suggestions: boolean
      -- needs the type report; only runs when type checking ran
      requires_types: boolean
      -- "off" | "warn" | "error" | "info" | "hint"
      default_severity: string
      default_options: {string:any}
   end

   record Report
      -- either a node (range = node start .. node end) or an explicit range
      node: ast_walk.AstNode
      y: integer
      x: integer
      yend: integer
      xend: integer
      message: string
      tags: {problem.Tag}
      fix: problem.Fix
      suggestions: {problem.Fix}
   end

   record Context
      rule_id: string
      filename: string
      is_lua: boolean
      options: {string:any}
      tokens: {tl.Token}
      ast: ast_walk.AstNode

      report: function(Context, Report)
      -- type recorded by the compiler at a position (1-based), refs resolved; nil if unknown
      type_at: function(Context, y: integer, x: integer): tl.TypeInfo
      -- start position of a node's source text
      node_start: function(Context, node: ast_walk.AstNode): integer, integer
      -- end position (line, exclusive column) of a node; positions at or after
      -- the optional limit are ignored (see ast_walk.node_end)
      node_end: function(Context, node: ast_walk.AstNode, limit_y?: integer, limit_x?: integer): integer, integer
   end

   record Rule
      meta: Meta
      create: function(ctx: Context): {string:ast_walk.Listener}
   end
end

return rule
