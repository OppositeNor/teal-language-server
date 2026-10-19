-- Built-in rule registry and configuration resolution.
--
-- Lint configuration lives in tlconfig.lua under the `externals` table, which
-- tl and cyan reserve for external tools:
--
--    externals = {
--       teal_language_server = {
--          rules = {
--             ["unreachable-code"] = "error",
--             ["implicit-any"] = { "warn", { ignore_pattern = "^_" } },
--             ["self-assignment"] = "off",
--             ["tl/unused"] = "off",           -- compiler warning kinds too
--          },
--          report_unused_directives = "warn",
--       },
--    }
--
-- Severity values follow ESLint: "off"/"warn"/"error" or 0/1/2 (plus "info"
-- and "hint"). A table value is { severity, options }; options are deep-merged
-- over the rule's `default_options`. Problems in the configuration never abort
-- analysis; they are collected as warnings for the user.

local tl <const> = require("tl")
local problem <const> = require("teal_language_server.analysis.diagnostics.problem")
local rule <const> = require("teal_language_server.analysis.diagnostics.rule")

local record rule_registry
   record RuleSetting
      severity: problem.Severity
      options: {string:any}
   end

   record Settings
      -- enabled lint rules only, keyed by rule id
      rules: {string:RuleSetting}
      -- severity per compiler warning kind; absent kinds are disabled
      tl_warnings: {string:problem.Severity}
      -- nil disables reporting of unused suppression directives
      unused_directives: problem.Severity
   end

   -- built-in rules in registration order
   rules: {rule.Rule}
   by_id: {string:rule.Rule}
end

rule_registry.rules = {
   (require("teal_language_server.analysis.diagnostics.rules.unreachable_code")) as rule.Rule,
   (require("teal_language_server.analysis.diagnostics.rules.self_assignment")) as rule.Rule,
   (require("teal_language_server.analysis.diagnostics.rules.implicit_any")) as rule.Rule,
}

rule_registry.by_id = {}
for _, r in ipairs(rule_registry.rules) do
   rule_registry.by_id[r.meta.id] = r
end

local severity_names: {any:string} = {
   off = "off", [0] = "off", ["0"] = "off",
   warn = "warning", warning = "warning", [1] = "warning", ["1"] = "warning",
   error = "error", [2] = "error", ["2"] = "error",
   info = "info",
   hint = "hint",
}

-- Returns the normalized severity ("off" or a problem.Severity) or nil if invalid.
function rule_registry.normalize_severity(value: any): string
   if type(value) == "string" then
      value = (value as string):lower()
   end
   return severity_names[value]
end

local function deep_merge(base: {string:any}, override: {string:any}): {string:any}
   local out: {string:any} = {}
   for k, v in pairs(base or {}) do
      out[k] = v
   end
   for k, v in pairs(override or {}) do
      local b = out[k]
      if type(v) == "table" and type(b) == "table" and #(v as {any}) == 0 and #(b as {any}) == 0 then
         out[k] = deep_merge(b as {string:any}, v as {string:any})
      else
         out[k] = v
      end
   end
   return out
end

-- `rules_config` is the user's `rules` table (may be nil), `disable_warnings`
-- and `warning_error` the top-level tlconfig keys tl itself understands.
function rule_registry.resolve(rules_config: any, disable_warnings: {string}, warning_error: {string}, unused_directives: any): rule_registry.Settings, {string}
   local warnings: {string} = {}
   local settings: rule_registry.Settings = { rules = {}, tl_warnings = {} }

   -- compiler warnings: on by default as warnings, unless tlconfig says otherwise
   for kind in pairs(tl.warning_kinds) do
      settings.tl_warnings[kind] = "warning"
   end
   for _, kind in ipairs(disable_warnings or {}) do
      settings.tl_warnings[kind] = nil
   end
   for _, kind in ipairs(warning_error or {}) do
      if settings.tl_warnings[kind] then
         settings.tl_warnings[kind] = "error"
      end
   end

   for _, r in ipairs(rule_registry.rules) do
      local sev = rule_registry.normalize_severity(r.meta.default_severity)
      if sev ~= "off" then
         settings.rules[r.meta.id] = { severity = sev as problem.Severity, options = deep_merge(r.meta.default_options, {}) }
      end
   end

   if rules_config ~= nil and type(rules_config) ~= "table" then
      table.insert(warnings, "externals.teal_language_server.rules must be a table")
      rules_config = nil
   end

   local ids: {string} = {}
   for id in pairs((rules_config or {}) as {string:any}) do
      if type(id) == "string" then
         table.insert(ids, id)
      end
   end
   table.sort(ids)

   for _, id in ipairs(ids) do
      local value = (rules_config as {string:any})[id]
      local sev_value: any = value
      local options: {string:any}
      if type(value) == "table" then
         sev_value = (value as {any})[1]
         options = (value as {any})[2] as {string:any}
         if options ~= nil and type(options) ~= "table" then
            table.insert(warnings, string.format("Options for rule '%s' must be a table", id))
            options = nil
         end
      end
      local sev = rule_registry.normalize_severity(sev_value)

      local tl_kind = id:match("^tl/(.+)$")
      if sev == nil then
         table.insert(warnings, string.format("Invalid severity for rule '%s': %s", id, tostring(sev_value)))
      elseif tl_kind then
         if not tl.warning_kinds[tl_kind as tl.WarningKind] then
            table.insert(warnings, string.format("Unknown compiler warning kind '%s'", id))
         elseif sev == "off" then
            settings.tl_warnings[tl_kind] = nil
         else
            settings.tl_warnings[tl_kind] = sev as problem.Severity
         end
      else
         local r = rule_registry.by_id[id]
         if r == nil then
            table.insert(warnings, string.format("Unknown rule '%s'", id))
         elseif sev == "off" then
            settings.rules[id] = nil
         else
            settings.rules[id] = {
               severity = sev as problem.Severity,
               options = deep_merge(r.meta.default_options, options or {}),
            }
         end
      end
   end

   if unused_directives ~= nil and unused_directives ~= false then
      local sev = unused_directives == true and "warning" or rule_registry.normalize_severity(unused_directives)
      if sev == nil then
         table.insert(warnings, "Invalid value for report_unused_directives: " .. tostring(unused_directives))
      elseif sev ~= "off" then
         settings.unused_directives = sev as problem.Severity
      end
   end

   return settings, warnings
end

-- Reads lint settings from a tlconfig table (fields as in ServerState.TealProjectConfig).
function rule_registry.resolve_from_config(config: {string:any}): rule_registry.Settings, {string}
   config = config or {}
   local externals = config.externals
   local ours: {string:any}
   if type(externals) == "table" then
      ours = (externals as {string:any}).teal_language_server as {string:any}
   end
   if ours ~= nil and type(ours) ~= "table" then
      return rule_registry.resolve(nil, config.disable_warnings as {string}, config.warning_error as {string}, nil),
         { "externals.teal_language_server must be a table" }
   end
   ours = ours or {}
   return rule_registry.resolve(ours.rules, config.disable_warnings as {string}, config.warning_error as {string}, ours.report_unused_directives)
end

return rule_registry
