-- The single intermediate representation for everything the diagnostics
-- engine reports, whether it comes from the tl compiler or from a lint rule.
--
-- Positions are tl coordinates: 1-based line, 1-based *byte* column. Ranges are
-- end-exclusive. Conversion to LSP (0-based, UTF-16) happens only when
-- publishing, see Document:problem_to_diagnostic.

local record problem
   enum Severity
      "error"
      "warning"
      "info"
      "hint"
   end

   -- LSP DiagnosticTag values
   enum Tag
      "unnecessary"
      "deprecated"
   end

   record TextEdit
      y: integer
      x: integer
      yend: integer
      xend: integer
      text: string
   end

   record Fix
      title: string
      edits: {TextEdit}
   end

   record Problem
      rule_id: string
      severity: Severity
      message: string
      y: integer
      x: integer
      yend: integer
      xend: integer
      tags: {Tag}
      -- safe, automatically applicable fix (used by quick fix and fix-all)
      fix: Fix
      -- alternative edits the user must pick explicitly; never applied by fix-all
      suggestions: {Fix}
   end
end

-- Deterministic ordering: position, then rule id, then message.
function problem.compare(a: problem.Problem, b: problem.Problem): boolean
   if a.y ~= b.y then return a.y < b.y end
   if a.x ~= b.x then return a.x < b.x end
   if a.rule_id ~= b.rule_id then return a.rule_id < b.rule_id end
   return a.message < b.message
end

function problem.sort(problems: {problem.Problem})
   table.sort(problems, problem.compare)
end

function problem.has_tag(p: problem.Problem, tag: problem.Tag): boolean
   for _, t in ipairs(p.tags or {}) do
      if t == tag then
         return true
      end
   end
   return false
end

return problem
