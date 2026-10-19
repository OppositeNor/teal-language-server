-- Applies text edits expressed in tl coordinates (1-based line, 1-based byte
-- column, end exclusive) to a string.
--
-- Mirrors ESLint's source-code-fixer: edits are sorted by range and applied in
-- one left-to-right sweep; an edit that overlaps an already-applied one is
-- skipped (and returned) rather than risking corrupted output.

local problem <const> = require("teal_language_server.analysis.diagnostics.problem")

local record fixer
end

-- Byte offset (1-based) of each line start.
local function line_starts(text: string): {integer}
   local starts = { 1 }
   local i = 1
   while true do
      local nl = text:find("\n", i, true)
      if not nl then break end
      table.insert(starts, nl + 1)
      i = nl + 1
   end
   return starts
end

-- 1-based byte offset of a tl position, clamped to the text.
local function offset(starts: {integer}, text: string, y: integer, x: integer): integer
   local s = starts[y]
   if s == nil then
      return #text + 1
   end
   local next_start = starts[y + 1] or (#text + 2)
   local o = s + x - 1
   -- never run past the line terminator into the next line
   if o > next_start - 1 then
      o = next_start - 1
   end
   if o > #text + 1 then
      o = #text + 1
   end
   return o
end

-- Returns the new text and the edits that were skipped because they overlapped.
function fixer.apply(text: string, edits: {problem.TextEdit}): string, {problem.TextEdit}
   local starts = line_starts(text)
   local record Resolved
      s: integer
      e: integer
      edit: problem.TextEdit
      order: integer
   end
   local resolved: {Resolved} = {}
   for i, edit in ipairs(edits) do
      local s = offset(starts, text, edit.y, edit.x)
      local e = offset(starts, text, edit.yend, edit.xend)
      if e < s then e = s end
      table.insert(resolved, { s = s, e = e, edit = edit, order = i })
   end
   table.sort(resolved, function(a: Resolved, b: Resolved): boolean
      if a.s ~= b.s then return a.s < b.s end
      if a.e ~= b.e then return a.e < b.e end
      return a.order < b.order
   end)

   local out: {string} = {}
   local skipped: {problem.TextEdit} = {}
   local pos = 1
   for _, r in ipairs(resolved) do
      if r.s < pos then
         table.insert(skipped, r.edit)
      else
         table.insert(out, text:sub(pos, r.s - 1))
         table.insert(out, r.edit.text)
         pos = r.e
      end
   end
   table.insert(out, text:sub(pos))
   return table.concat(out), skipped
end

-- Applies whole fixes atomically: a fix whose overall span overlaps an
-- already-accepted fix is skipped entirely, so multi-edit fixes are never
-- half-applied. Returns the new text and the number of fixes applied.
function fixer.apply_fixes(text: string, fixes: {problem.Fix}): string, integer
   local starts = line_starts(text)
   local record Span
      s: integer
      e: integer
      fix: problem.Fix
      order: integer
   end
   local spans: {Span} = {}
   for i, fix in ipairs(fixes) do
      if fix.edits and #fix.edits > 0 then
         local s, e: integer, integer
         for _, edit in ipairs(fix.edits) do
            local es = offset(starts, text, edit.y, edit.x)
            local ee = offset(starts, text, edit.yend, edit.xend)
            if s == nil or es < s then s = es end
            if e == nil or ee > e then e = ee end
         end
         table.insert(spans, { s = s, e = e, fix = fix, order = i })
      end
   end
   table.sort(spans, function(a: Span, b: Span): boolean
      if a.s ~= b.s then return a.s < b.s end
      if a.e ~= b.e then return a.e < b.e end
      return a.order < b.order
   end)
   local edits: {problem.TextEdit} = {}
   local last_end = 0
   local last_insert_at = -1
   local applied = 0
   for _, sp in ipairs(spans) do
      -- fixes may touch (e.g. deleting two consecutive lines) but not overlap;
      -- two insertions at the same position are ambiguous, so the later one waits
      -- for the next pass
      local is_insert = sp.s == sp.e
      if sp.s >= last_end and not (is_insert and sp.s == last_insert_at) then
         for _, edit in ipairs(sp.fix.edits) do
            table.insert(edits, edit)
         end
         last_end = sp.e
         last_insert_at = is_insert and sp.s or -1
         applied = applied + 1
      end
   end
   local new_text = fixer.apply(text, edits)
   return new_text, applied
end

-- Collects the edits of every problem's `fix` (never suggestions).
function fixer.collect_fix_edits(problems: {problem.Problem}): {problem.TextEdit}
   local edits: {problem.TextEdit} = {}
   for _, p in ipairs(problems) do
      if p.fix then
         for _, e in ipairs(p.fix.edits) do
            table.insert(edits, e)
         end
      end
   end
   return edits
end

return fixer
