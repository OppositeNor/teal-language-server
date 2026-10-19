local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table





















local tl = require("tl")
local problem = require("teal_language_server.analysis.diagnostics.problem")
local rule = require("teal_language_server.analysis.diagnostics.rule")

local rule_registry = { RuleSetting = {}, Settings = {} }



















rule_registry.rules = {
   (require("teal_language_server.analysis.diagnostics.rules.unreachable_code")),
   (require("teal_language_server.analysis.diagnostics.rules.self_assignment")),
   (require("teal_language_server.analysis.diagnostics.rules.implicit_any")),
}

rule_registry.by_id = {}
for _, r in ipairs(rule_registry.rules) do
   rule_registry.by_id[r.meta.id] = r
end

local severity_names = {
   off = "off", [0] = "off", ["0"] = "off",
   warn = "warning", warning = "warning", [1] = "warning", ["1"] = "warning",
   error = "error", [2] = "error", ["2"] = "error",
   info = "info",
   hint = "hint",
}


function rule_registry.normalize_severity(value)
   if type(value) == "string" then
      value = (value):lower()
   end
   return severity_names[value]
end

local function deep_merge(base, override)
   local out = {}
   for k, v in pairs(base or {}) do
      out[k] = v
   end
   for k, v in pairs(override or {}) do
      local b = out[k]
      if type(v) == "table" and type(b) == "table" and #(v) == 0 and #(b) == 0 then
         out[k] = deep_merge(b, v)
      else
         out[k] = v
      end
   end
   return out
end



function rule_registry.resolve(rules_config, disable_warnings, warning_error, unused_directives)
   local warnings = {}
   local settings = { rules = {}, tl_warnings = {} }


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
         settings.rules[r.meta.id] = { severity = sev, options = deep_merge(r.meta.default_options, {}) }
      end
   end

   if rules_config ~= nil and type(rules_config) ~= "table" then
      table.insert(warnings, "externals.teal_language_server.rules must be a table")
      rules_config = nil
   end

   local ids = {}
   for id in pairs((rules_config or {})) do
      if type(id) == "string" then
         table.insert(ids, id)
      end
   end
   table.sort(ids)

   for _, id in ipairs(ids) do
      local value = (rules_config)[id]
      local sev_value = value
      local options
      if type(value) == "table" then
         sev_value = (value)[1]
         options = (value)[2]
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
         if not tl.warning_kinds[tl_kind] then
            table.insert(warnings, string.format("Unknown compiler warning kind '%s'", id))
         elseif sev == "off" then
            settings.tl_warnings[tl_kind] = nil
         else
            settings.tl_warnings[tl_kind] = sev
         end
      else
         local r = rule_registry.by_id[id]
         if r == nil then
            table.insert(warnings, string.format("Unknown rule '%s'", id))
         elseif sev == "off" then
            settings.rules[id] = nil
         else
            settings.rules[id] = {
               severity = sev,
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
         settings.unused_directives = sev
      end
   end

   return settings, warnings
end


function rule_registry.resolve_from_config(config)
   config = config or {}
   local externals = config.externals
   local ours
   if type(externals) == "table" then
      ours = (externals).teal_language_server
   end
   if ours ~= nil and type(ours) ~= "table" then
      return rule_registry.resolve(nil, config.disable_warnings, config.warning_error, nil),
      { "externals.teal_language_server must be a table" }
   end
   ours = ours or {}
   return rule_registry.resolve(ours.rules, config.disable_warnings, config.warning_error, ours.report_unused_directives)
end

return rule_registry
