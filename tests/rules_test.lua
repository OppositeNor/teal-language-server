package.path = "./?.lua;" .. package.path

-- In-process tests for the diagnostics engine and lint rules (no LSP round trip),
-- in the style of ESLint's RuleTester.

local tested = require("tested")
local rule_tester = require("teal_language_server.analysis.diagnostics.rule_tester")
local rule_registry = require("teal_language_server.analysis.diagnostics.rule_registry")
local fixer = require("teal_language_server.analysis.diagnostics.fixer")

local function lines(...)
    return table.concat({ ... }, "\n")
end

local function assert_no_failures(rule_id, failures)
    tested.assert({
        given = rule_id .. " rule tester cases",
        should = "all pass",
        expected = "",
        actual = table.concat(failures, "\n"),
    })
end

local function ids(problems)
    local out = {}
    for _, p in ipairs(problems) do
        table.insert(out, p.y .. ":" .. p.x .. " " .. p.rule_id)
    end
    return table.concat(out, ", ")
end

-- rules ----------------------------------------------------------------------------

tested.test("rule unreachable-code", function()
    assert_no_failures("unreachable-code", rule_tester.run("unreachable-code", {
        valid = {
            { code = lines("for i = 1, 2 do", "  if i == 1 then break end", "  print(i)", "end") },
            { code = lines("for i = 1, 2 do", "  goto continue", "  ::continue::", "  print(i)", "end") },
            { code = lines("local function f(): integer", "  return 1", "end", "print(f())") },
        },
        invalid = {
            {
                code = lines("for i = 1, 2 do", "  break", "  print(i)", "end"),
                errors = { { message = "Unreachable code", line = 3, column = 3, end_line = 3, end_column = 11 } },
            },
            {
                -- the region ends at the label a goto may jump to
                code = lines("for i = 1, 3 do", "  goto continue", "  print(i)", "  print(i + 1)", "  ::continue::", "  print(0)", "end"),
                errors = { { line = 3, column = 3, end_line = 4, end_column = 15 } },
            },
            {
                code = lines("local function f(): integer", "  do return 1 end", "  return 2", "end", "print(f())"),
                errors = { { line = 3, column = 3, end_line = 3, end_column = 11 } },
            },
            {
                -- a local declaration starts at its `local` keyword
                code = lines("while true do", "  break", "  local x = 1", "  print(x)", "end"),
                errors = { { line = 3, column = 3, end_line = 4, end_column = 11 } },
            },
            {
                -- a multi-line statement is covered up to its closing `end`
                code = lines("while true do", "  break", "  if true then", "    print(1)", "  end", "end"),
                errors = { { line = 3, column = 3, end_line = 5, end_column = 6 } },
            },
        },
    }))
end)

tested.test("rule self-assignment", function()
    assert_no_failures("self-assignment", rule_tester.run("self-assignment", {
        valid = {
            { code = lines("local a, b = 1, 2", "a, b = b, a", "print(a, b)") },
            { code = lines("local t = {a = 1, b = 2}", "t.a = t.b") },
            { code = lines("local t = {1, 2}", "local i = 1", "t[i] = t[i]") },
        },
        invalid = {
            {
                code = lines("local a = 1", "a = a", "print(a)"),
                errors = { {
                    message = "Value is assigned to itself", line = 2, column = 1, end_line = 2, end_column = 6,
                    suggestion_output = lines("local a = 1", "", "print(a)"),
                } },
            },
            {
                -- inside if / elseif / else branches
                code = lines("local a = 1", "if a > 0 then", "  a = a", "elseif a < 0 then", "  a = a", "else", "  a = a", "end"),
                errors = { { line = 3, column = 3 }, { line = 5, column = 3 }, { line = 7, column = 3 } },
            },
            {
                code = lines("local t = {a = 1}", "t.a = t.a"),
                errors = { { line = 2, column = 1, end_line = 2, end_column = 10 } },
            },
            {
                -- dotted and constant-bracket access to the same key are the same reference
                code = lines("local t = {a = 1}", 't["a"] = t.a'),
                errors = { { line = 2, column = 1, end_line = 2, end_column = 13 } },
            },
            {
                -- only the self-assigned target is reported; no removal suggestion
                code = lines("local a, b = 1, 2", "a, b = a, 3", "print(a, b)"),
                errors = { { line = 2, column = 1, end_line = 2, end_column = 9 } },
            },
        },
    }))
end)

tested.test("rule implicit-any", function()
    assert_no_failures("implicit-any", rule_tester.run("implicit-any", {
        valid = {
            { code = lines("local function f(x: integer): integer return x end", "print(f(1))") },
            { code = lines("local function f(_x): integer return 1 end", "print(f(1))") },
            { code = lines("local function f(...: integer) print(...) end", "f(1)") },
            { code = lines("local record R end", "function R:m(a: integer) print(a) end") },
            -- .lua files are lax: not reported unless check_lua is set
            { code = lines("local function f(x) return x end", "print(f(1))"), filename = "lax.lua" },
        },
        invalid = {
            {
                code = lines("local function f(x): integer return 1 end", "print(f(1))"),
                errors = { {
                    message = "Parameter 'x' implicitly has an 'any' type", line = 1, column = 18, end_line = 1, end_column = 19,
                    suggestion_output = lines("local function f(x: any): integer return 1 end", "print(f(1))"),
                } },
            },
            {
                -- tl does not infer callback parameters from context
                code = lines("local t = {3, 1}", "table.sort(t, function(a, b): boolean return true end)"),
                errors = { { line = 2, column = 24 }, { line = 2, column = 27 } },
            },
            {
                code = lines("local function f(_x): integer return 1 end", "print(f(1))"),
                options = { ignore_pattern = "" },
                errors = { { line = 1, column = 18 } },
            },
            {
                code = lines("local function f(x) return x end", "print(f(1))"),
                filename = "strict.lua",
                options = { check_lua = true },
                errors = { { line = 1, column = 18 } },
            },
        },
    }))
end)

-- engine ---------------------------------------------------------------------------

tested.test("engine labels compiler problems with tl/<kind> codes and Unnecessary tags", function()
    local problems = rule_tester.lint(lines("local x = 1", "local y: integer = 'no'", "print(y)"))
    tested.assert({ given = "problems", should = "be sorted with codes", expected = "1:7 tl/unused, 2:20 tl/type-error", actual = ids(problems) })
    tested.assert({ given = "unused problem", should = "be tagged unnecessary", expected = "unnecessary", actual = problems[1].tags and problems[1].tags[1] or "none" })
    tested.assert({ given = "type error", should = "be an error", expected = "error", actual = problems[2].severity })
end)

tested.test("engine reports syntax errors only, without running rules", function()
    local problems = rule_tester.lint(lines("local a = 1", "a = a", "local x = = 1"))
    tested.assert({ given = "invalid code", should = "only have syntax errors", expected = true, actual = #problems > 0 })
    for _, p in ipairs(problems) do
        tested.assert({ given = "problem " .. p.message, should = "be a syntax error", expected = "tl/syntax-error", actual = p.rule_id })
    end
end)

tested.test("engine survives incomplete code", function()
    for _, code in ipairs({ "local function f(a", "local t = {", "for i = 1,", "x.", "local record R\n  f: function(", "" }) do
        local ok, err = pcall(rule_tester.lint, code)
        tested.assert({ given = string.format("%q", code), should = "not raise", expected = true, actual = ok or err })
    end
end)

tested.test("directives: disable-next-line, disable-line and block disable/enable", function()
    local problems = rule_tester.lint(lines(
        "local a = 1",
        "-- tls-disable-next-line self-assignment -- intentional",
        "a = a",
        "a = a -- tls-disable-line",
        "-- tls-disable",
        "a = a",
        "-- tls-enable",
        "a = a",
        "print(a)"))
    tested.assert({ given = "suppressed lines", should = "only report line 8", expected = "8:1 self-assignment", actual = ids(problems) })
end)

tested.test("directives: rule lists only suppress the listed rules", function()
    local problems = rule_tester.lint(lines(
        "local a = 1",
        "-- tls-disable-next-line implicit-any",
        "a = a",
        "print(a)"))
    tested.assert({ given = "unrelated directive", should = "not suppress", expected = "3:1 self-assignment", actual = ids(problems) })
end)

tested.test("directives: block enable of one rule inside a disable-all", function()
    local problems = rule_tester.lint(lines(
        "local a = 1",
        "-- tls-disable",
        "-- tls-enable self-assignment",
        "a = a",
        "local unused = 2",
        "print(a)"))
    tested.assert({ given = "re-enabled rule", should = "still report", expected = "4:1 self-assignment", actual = ids(problems) })
end)

tested.test("directives: compiler warnings can be suppressed, trailing comment without newline", function()
    local problems = rule_tester.lint("local x = 1 -- tls-disable-line tl/unused")
    tested.assert({ given = "suppressed unused warning", should = "report nothing", expected = "", actual = ids(problems) })
end)

tested.test("directives: unused directives are reported with a removal fix when enabled", function()
    local code = lines("-- tls-disable-next-line self-assignment", "local a = 1", "print(a)")
    local problems = rule_tester.lint(code, nil, nil, "warn")
    tested.assert({ given = "unused directive", should = "be reported", expected = "1:1 tls/unused-directive", actual = ids(problems) })
    local fixed = fixer.apply_fixes(code, { problems[1].fix })
    tested.assert({ given = "removal fix", should = "remove the comment", expected = lines("", "local a = 1", "print(a)"), actual = fixed })
    tested.assert({ given = "default settings", should = "not report unused directives", expected = "", actual = ids(rule_tester.lint(code)) })
end)

tested.test("config: severities, options and tl warning kinds", function()
    local p = rule_tester.lint(lines("local a = 1", "a = a", "print(a)"), nil, { ["self-assignment"] = "error" })
    tested.assert({ given = "self-assignment = error", should = "be an error", expected = "error", actual = p[1] and p[1].severity })

    p = rule_tester.lint(lines("local a = 1", "a = a", "print(a)"), nil, { ["self-assignment"] = 0 })
    tested.assert({ given = "self-assignment = 0", should = "be off", expected = "", actual = ids(p) })

    p = rule_tester.lint("local x = 1", nil, { ["tl/unused"] = "off" })
    tested.assert({ given = "tl/unused = off", should = "hide unused warnings", expected = "", actual = ids(p) })

    p = rule_tester.lint("local x = 1", nil, { ["tl/unused"] = "error" })
    tested.assert({ given = "tl/unused = error", should = "be an error", expected = "error", actual = p[1] and p[1].severity })

    local _, warnings = rule_registry.resolve({ ["no-such-rule"] = "warn", ["self-assignment"] = "loud", ["tl/bogus"] = "off" })
    tested.assert({ given = "bad config entries", should = "produce three warnings", expected = 3, actual = #warnings })

    local settings = rule_registry.resolve({ ["implicit-any"] = { "warn", { check_lua = true } } })
    local opts = settings.rules["implicit-any"].options
    tested.assert({ given = "options override", should = "merge over defaults", expected = "true ^_", actual = tostring(opts.check_lua) .. " " .. opts.ignore_pattern })

    local s2 = rule_registry.resolve(nil, { "unused" }, { "redeclaration" })
    tested.assert({ given = "tlconfig disable_warnings/warning_error", should = "be honoured", expected = "nil error", actual = tostring(s2.tl_warnings.unused) .. " " .. s2.tl_warnings.redeclaration })
end)

tested.test("fixer: overlapping fixes are skipped and applied atomically", function()
    local text = "abcdef"
    local out, applied = fixer.apply_fixes(text, {
        { title = "a", edits = { { y = 1, x = 1, yend = 1, xend = 3, text = "X" } } },
        { title = "overlaps a", edits = { { y = 1, x = 2, yend = 1, xend = 4, text = "Y" } } },
        { title = "two edits", edits = { { y = 1, x = 5, yend = 1, xend = 5, text = "<" }, { y = 1, x = 7, yend = 1, xend = 7, text = ">" } } },
    })
    tested.assert({ given = "three fixes, one overlapping", should = "apply two", expected = "Xcd<ef>", actual = out })
    tested.assert({ given = "applied count", should = "be 2", expected = 2, actual = applied })

    local multi = fixer.apply("l1\nl2\nl3", { { y = 2, x = 1, yend = 3, xend = 1, text = "" } })
    tested.assert({ given = "a line-deleting edit", should = "remove the line", expected = "l1\nl3", actual = multi })
end)

return tested
