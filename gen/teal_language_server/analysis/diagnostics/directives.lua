local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table










local tl = require("tl")
local problem = require("teal_language_server.analysis.diagnostics.problem")

local directives = { Directive = {} }






















local kinds = {
   ["disable"] = "disable",
   ["enable"] = "enable",
   ["disable-line"] = "disable-line",
   ["disable-next-line"] = "disable-next-line",
}

local function comment_end(c)
   local lines = 0
   local last_nl
   local i = 1
   while true do
      local nl = c.text:find("\n", i, true)
      if not nl then break end
      lines = lines + 1
      last_nl = nl
      i = nl + 1
   end
   if lines == 0 then
      return c.y, c.x + #c.text
   end
   return c.y + lines, #c.text - last_nl + 1
end

local function parse_comment(c)
   local body = c.text:match("^%-%-%[=*%[(.*)%]=*%]$") or c.text:match("^%-%-(.*)$")
   if not body then
      return nil
   end
   local kind_str, rest = body:match("^%s*tls%-([%a%-]+)(.*)$")
   if not kind_str then
      return nil
   end
   local kind = kinds[kind_str]
   if not kind then
      return nil
   end
   if rest ~= "" and not rest:match("^%s") then
      return nil
   end

   rest = rest:gsub("%s%-%-.*$", "")
   local rules
   for name in rest:gmatch("[^%s,]+") do
      rules = rules or {}
      table.insert(rules, name)
   end
   local yend, xend = comment_end(c)
   local d = {
      kind = kind,
      rules = rules,
      y = c.y,
      x = c.x,
      yend = yend,
      xend = xend,
   }
   if kind == "disable-line" then
      d.target_line = c.y
   elseif kind == "disable-next-line" then
      d.target_line = yend + 1
   end
   return d
end


function directives.parse(tokens)
   local out = {}
   for _, tok in ipairs(tokens or {}) do
      for _, c in ipairs(tok.comments or {}) do
         local d = parse_comment(c)
         if d then
            table.insert(out, d)
         end
      end
   end
   table.sort(out, function(a, b)
      return a.y < b.y or (a.y == b.y and a.x < b.x)
   end)
   return out
end

local function matches(d, rule_id)
   if d.rules == nil then
      return true
   end
   for _, r in ipairs(d.rules) do
      if r == rule_id then
         return true
      end
   end
   return false
end


local function is_suppressed(p, list)

   for _, d in ipairs(list) do
      if d.target_line == p.y and matches(d, p.rule_id) then
         d.used = true
         return true
      end
   end


   local all_disabled = nil
   local disabled = {}
   local reenabled = {}
   for _, d in ipairs(list) do
      if d.y > p.y or (d.y == p.y and d.x > p.x) then
         break
      end
      if d.kind == "disable" then
         if d.rules == nil then
            all_disabled = d
            reenabled = {}
         else
            for _, r in ipairs(d.rules) do
               disabled[r] = d
               reenabled[r] = nil
            end
         end
      elseif d.kind == "enable" then
         if d.rules == nil then
            all_disabled = nil
            disabled = {}
            reenabled = {}
         else
            for _, r in ipairs(d.rules) do
               disabled[r] = nil
               if all_disabled then
                  reenabled[r] = true
               end
            end
         end
      end
   end

   local by_rule = disabled[p.rule_id]
   if by_rule then
      by_rule.used = true
      return true
   end
   if all_disabled and not reenabled[p.rule_id] then
      all_disabled.used = true
      return true
   end
   return false
end



function directives.apply(problems, list, unused_severity)
   if #list == 0 then
      return problems
   end
   local kept = {}
   for _, p in ipairs(problems) do
      if not is_suppressed(p, list) then
         table.insert(kept, p)
      end
   end
   if unused_severity then
      for _, d in ipairs(list) do
         if d.kind ~= "enable" and not d.used then
            table.insert(kept, {
               rule_id = "tls/unused-directive",
               severity = unused_severity,
               message = "Unused suppression directive (no problems were reported" ..
               (d.rules and (" for " .. table.concat(d.rules, ", ")) or "") .. ")",
               y = d.y,
               x = d.x,
               yend = d.yend,
               xend = d.xend,
               tags = { "unnecessary" },
               fix = {
                  title = "Remove unused suppression comment",
                  edits = { { y = d.y, x = d.x, yend = d.yend, xend = d.xend, text = "" } },
               },
            })
         end
      end
   end
   return kept
end

return directives
