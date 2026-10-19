-- In-process test harness for lint rules, modeled on ESLint's RuleTester.
--
--    local failures = rule_tester.run("self-assignment", {
--       valid = { { code = "local a = 1\nlocal b = a\nprint(b)" } },
--       invalid = {
--          { code = "local a = 1\na = a\nprint(a)",
--            errors = { { message = "Value is assigned to itself", line = 2, column = 1 } } },
--       },
--    })
--
-- Positions are tl coordinates (1-based line and byte column, end exclusive).
-- Each case is linted with a fresh compiler environment and only the rule under
-- test enabled. Returns a list of human-readable failure descriptions.

local tl <const> = require("tl")
local linter <const> = require("teal_language_server.analysis.diagnostics.linter")
local fixer <const> = require("teal_language_server.analysis.diagnostics.fixer")
local problem <const> = require("teal_language_server.analysis.diagnostics.problem")
local rule_registry <const> = require("teal_language_server.analysis.diagnostics.rule_registry")

local record rule_tester
   record ExpectedError
      message: string
      line: integer
      column: integer
      end_line: integer
      end_column: integer
      -- expected text after applying the first suggestion (if any)
      suggestion_output: string
   end

   record ValidCase
      code: string
      filename: string
      options: {string:any}
   end

   record InvalidCase
      code: string
      filename: string
      options: {string:any}
      errors: {ExpectedError}
      -- expected text after applying all fixes; nil means the rule must not fix
      output: string
   end

   record Cases
      valid: {ValidCase}
      invalid: {InvalidCase}
   end
end

-- Lints `code` with the given `rules` configuration (same shape as
-- externals.teal_language_server.rules). Returns all problems.
function rule_tester.lint(code: string, filename?: string, rules?: {string:any}, unused_directives?: any): {problem.Problem}
   local settings = rule_registry.resolve(rules, nil, nil, unused_directives)
   return linter.lint_text(code, filename or "test.tl", settings)
end

-- Lints with only `rule_id` enabled (as an error) and returns its problems.
function rule_tester.lint_rule(rule_id: string, code: string, filename?: string, options?: {string:any}): {problem.Problem}
   local rules: {string:any} = {}
   for _, r in ipairs(rule_registry.rules) do
      rules[r.meta.id] = "off"
   end
   rules[rule_id] = { "error", options or {} }
   local out: {problem.Problem} = {}
   for _, p in ipairs(rule_tester.lint(code, filename, rules)) do
      if p.rule_id == rule_id then
         table.insert(out, p)
      end
   end
   return out
end

local function describe(p: problem.Problem): string
   return string.format("%d:%d-%d:%d %q", p.y, p.x, p.yend, p.xend, p.message)
end

function rule_tester.run(rule_id: string, cases: rule_tester.Cases): {string}
   local failures: {string} = {}
   local function fail(kind: string, i: integer, msg: string)
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
         local got: {string} = {}
         for _, p in ipairs(problems) do table.insert(got, describe(p)) end
         fail("invalid", i, string.format("expected %d problem(s), got %d: %s", #expected, #problems, table.concat(got, "; ")))
      else
         for j, e in ipairs(expected) do
            local p = problems[j]
            local function check(field: string, want: any, got: any)
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

      local fixes: {problem.Fix} = {}
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
         -- like ESLint, a fix must never produce code that no longer parses
         local _, perrs = tl.parse(fixed, case.filename or "test.tl")
         if #perrs > 0 then
            fail("invalid", i, "fix output does not parse: " .. perrs[1].msg)
         end
      end
   end

   return failures
end

return rule_tester
