local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local table = _tl_compat and _tl_compat.table or table






local problem = { TextEdit = {}, Fix = {}, Problem = {} }











































function problem.compare(a, b)
   if a.y ~= b.y then return a.y < b.y end
   if a.x ~= b.x then return a.x < b.x end
   if a.rule_id ~= b.rule_id then return a.rule_id < b.rule_id end
   return a.message < b.message
end

function problem.sort(problems)
   table.sort(problems, problem.compare)
end

function problem.has_tag(p, tag)
   for _, t in ipairs(p.tags or {}) do
      if t == tag then
         return true
      end
   end
   return false
end

return problem
