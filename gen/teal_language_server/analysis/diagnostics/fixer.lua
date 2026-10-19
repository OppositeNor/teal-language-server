local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table






local problem = require("teal_language_server.analysis.diagnostics.problem")

local fixer = {}



local function line_starts(text)
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


local function offset(starts, text, y, x)
   local s = starts[y]
   if s == nil then
      return #text + 1
   end
   local next_start = starts[y + 1] or (#text + 2)
   local o = s + x - 1

   if o > next_start - 1 then
      o = next_start - 1
   end
   if o > #text + 1 then
      o = #text + 1
   end
   return o
end


function fixer.apply(text, edits)
   local starts = line_starts(text)






   local resolved = {}
   for i, edit in ipairs(edits) do
      local s = offset(starts, text, edit.y, edit.x)
      local e = offset(starts, text, edit.yend, edit.xend)
      if e < s then e = s end
      table.insert(resolved, { s = s, e = e, edit = edit, order = i })
   end
   table.sort(resolved, function(a, b)
      if a.s ~= b.s then return a.s < b.s end
      if a.e ~= b.e then return a.e < b.e end
      return a.order < b.order
   end)

   local out = {}
   local skipped = {}
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




function fixer.apply_fixes(text, fixes)
   local starts = line_starts(text)






   local spans = {}
   for i, fix in ipairs(fixes) do
      if fix.edits and #fix.edits > 0 then
         local s, e
         for _, edit in ipairs(fix.edits) do
            local es = offset(starts, text, edit.y, edit.x)
            local ee = offset(starts, text, edit.yend, edit.xend)
            if s == nil or es < s then s = es end
            if e == nil or ee > e then e = ee end
         end
         table.insert(spans, { s = s, e = e, fix = fix, order = i })
      end
   end
   table.sort(spans, function(a, b)
      if a.s ~= b.s then return a.s < b.s end
      if a.e ~= b.e then return a.e < b.e end
      return a.order < b.order
   end)
   local edits = {}
   local last_end = 0
   local last_insert_at = -1
   local applied = 0
   for _, sp in ipairs(spans) do



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


function fixer.collect_fix_edits(problems)
   local edits = {}
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
