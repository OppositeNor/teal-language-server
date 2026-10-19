local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table













local tl = require("tl")
local linter = require("teal_language_server.analysis.diagnostics.linter")
local fixer = require("teal_language_server.analysis.diagnostics.fixer")
local problem = require("teal_language_server.analysis.diagnostics.problem")
local rule_registry = require("teal_language_server.analysis.diagnostics.rule_registry")

local rule_tester = { ExpectedError = {}, ValidCase = {}, InvalidCase = {}, Cases = {} }

































function rule_tester.lint(code, filename, rules, unused_directives)
   local settings = rule_registry.resolve(rules, nil, nil, unused_directives)
   return linter.lint_text(code, filename or "test.tl", settings)
end


function rule_tester.lint_rule(rule_id, code, filename, options)
   local rules = {}
   for _, r in ipairs(rule_registry.rules) do
      rules[r.meta.id] = "off"
   end
   rules[rule_id] = { "error", options or {} }
   local out = {}
   for _, p in ipairs(rule_tester.lint(code, filename, rules)) do
      if p.rule_id == rule_id then
         table.insert(out, p)
      end
   end
   return out
end

local function describe(p)
   return string.format("%d:%d-%d:%d %q", p.y, p.x, p.yend, p.xend, p.message)
end

function rule_tester.run(rule_id, cases)
   local failures = {}
   local function fail(kind, i, msg)
      table.insert(failures, string.format("%s %s case #%d: %s", rule_id, kind, i, msg))
   end

   if rule_registry.by_id[rule_id] == nil then
      return { "unknown rule " .. rule_id }
   end

   for i, case in ipairs(cases.valid or {}) do
      local problems = rule_tester.lint_rule(rule_id, case.code, case.filename, case.options)
      for _, p in ipairs(problems) do
         fail("valid", i, "unexpected problem " .. describe(p))
      end
   end

   for i, case in ipairs(cases.invalid or {}) do
      local problems = rule_tester.lint_rule(rule_id, case.code, case.filename, case.options)
      local expected = case.errors or {}
      if #problems ~= #expected then
         local got = {}
         for _, p in ipairs(problems) do table.insert(got, describe(p)) end
         fail("invalid", i, string.format("expected %d problem(s), got %d: %s", #expected, #problems, table.concat(got, "; ")))
      else
         for j, e in ipairs(expected) do
            local p = problems[j]
            local function check(field, want, got)
               if want ~= nil and want ~= got then
                  fail("invalid", i, string.format("problem %d: expected %s %s, got %s", j, field, tostring(want), tostring(got)))
               end
            end
            check("message", e.message, p.message)
            check("line", e.line, p.y)
            check("column", e.column, p.x)
            check("end_line", e.end_line, p.yend)
            check("end_column", e.end_column, p.xend)
            if e.suggestion_output ~= nil then
               local s = p.suggestions and p.suggestions[1]
               if s == nil then
                  fail("invalid", i, string.format("problem %d: expected a suggestion", j))
               else
                  check("suggestion output", e.suggestion_output, (fixer.apply(case.code, s.edits)))
               end
            end
         end
      end

      local fixes = {}
      for _, p in ipairs(problems) do
         if p.fix then table.insert(fixes, p.fix) end
      end
      if case.output == nil then
         if #fixes > 0 then
            fail("invalid", i, "rule produced a fix but no output was expected")
         end
      else
         local fixed = fixer.apply_fixes(case.code, fixes)
         if fixed ~= case.output then
            fail("invalid", i, string.format("fix output mismatch:\n--- expected\n%s\n--- got\n%s", case.output, fixed))
         end

         local _, perrs = tl.parse(fixed, case.filename or "test.tl")
         if #perrs > 0 then
            fail("invalid", i, "fix output does not parse: " .. perrs[1].msg)
         end
      end
   end

   return failures
end

return rule_tester
