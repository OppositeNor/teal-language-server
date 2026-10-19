local _module_name = "analysis.env_updater"

-- <imports>
local DocumentManager <const> = require("teal_language_server.analysis.document_manager")
local Document <const> = require("teal_language_server.analysis.document")
local lua_env <const> = require("teal_language_server.analysis.lua_env")
local lusc <const> = require("lusc")
local ServerState <const> = require("teal_language_server.server_state")
local tl <const> = require("tl")
local uv <const> = require("luv")
local asserts <const> = require("teal_language_server.util.asserts")
local logging <const> = require("teal_language_server.logging")
local class <const> = require("teal_language_server.util.class")

local logger = logging.get_logger(_module_name)

local init_path: string = package.path
local init_cpath: string = package.cpath

local function dedup_path(path_str: string): string
   local seen: {string: boolean} = {}
   local result: {string} = {}
   -- should keep the order, the de-duping feels a little risky, and this feels like it could be a premature optimzation?
   -- I'll keep it for now and hope we wont regret it later
   for entry in path_str:gmatch("[^;]+") do
      if not seen[entry] then
         seen[entry] = true
         table.insert(result, entry)
      end
   end
   return table.concat(result, ";")
end

-- A minimal file object over a string: tl only calls read("*a") and close()
-- on the handle returned by tl.search_module.
local record StringFile
   content: string
end

function StringFile:read(_fmt: any): string
   local c = self.content
   self.content = nil
   return c
end

function StringFile:close(): boolean
   return true
end

local record EnvUpdater
   _document_manager: DocumentManager
   _server_state: ServerState
   _root_nursery:lusc.Nursery
   _change_detected: lusc.StickyEvent

   -- latest pending (debounced) analysis version per document path
   _pending_analysis: {string:integer}
   -- type report size right after the last env (re)build
   _type_baseline: integer
   _env_rebuilds: integer
   -- files (absolute paths) whose text changed since the last env build:
   -- the documents depending on them are re-checked eagerly after it
   _changed: {string:boolean}

   type_count: function(EnvUpdater): integer
   schedule_env_update: function(EnvUpdater, changed_path?: string)
   dependency_closure: function(EnvUpdater, Document): {string:boolean}
   _affected_documents: function(EnvUpdater, {string:boolean}): {string:boolean}

   metamethod __call: function(self: EnvUpdater, server_state: ServerState, root_nursery:lusc.Nursery, document_manager: DocumentManager): EnvUpdater
end

function EnvUpdater:__init(server_state: ServerState, root_nursery:lusc.Nursery, document_manager: DocumentManager)
   asserts.is_not_nil(document_manager)

   self._change_detected = lusc.new_sticky_event()
   self._pending_analysis = {}
   self._type_baseline = 0
   self._env_rebuilds = 0
   self._changed = {}
   self._server_state = server_state
   self._root_nursery = root_nursery
   self._document_manager = document_manager
end

function EnvUpdater:_init_env_from_config(cfg: ServerState.TealProjectConfig): tl.Env, string
   local function ivalues<Value>(t: {any:Value}): function(): Value
      local i = 0
      return function(): Value
         i = i + 1
         return t[i]
      end
   end

   local path_separator = package.config:sub(1, 1)
   local shared_lib_ext = package.cpath:match("(%.%w+)%s*$") or ".so"

   local function prepend_to_lua_path(path_str: string)
      if path_str:sub(-1) == path_separator then
         path_str = path_str:sub(1, -2)
      end

      path_str = path_str .. path_separator

      package.path = path_str .. "?.lua;"
         .. path_str .. "?" .. path_separator .. "init.lua;"
         .. package.path

      package.cpath = path_str .. "?." .. shared_lib_ext .. ";"
         .. package.cpath
   end

   local function init_teal_env(gen_compat: tl.GenCompat, gen_target: tl.GenTarget, env_def: string): tl.Env, string
      local opts:tl.EnvOptions = {
         defaults = {
            gen_compat = gen_compat,
            gen_target = gen_target,
         },
         predefined_modules = {env_def},
      }

      local env = tl.new_env(opts)
      env.report_types = true
      -- initializes an empty string, so even if the file is not valid, completions should work
      tl.check_string("", env, "bootstrap.tl")
      return env
   end

   cfg = cfg or {}

   for dir in ivalues(cfg.include_dir or {}) do
      prepend_to_lua_path(dir)
   end

   if cfg.source_dir then
      prepend_to_lua_path(cfg.source_dir)
   end

   logger:debug("Final package.path: %s", package.path)
   logger:debug("Final package.cpath: %s", package.cpath)

   local env, err = init_teal_env(cfg.gen_compat, cfg.gen_target, cfg.global_env_def)
   if not env then
      return nil, err
   end

   return env
end

function EnvUpdater:_generate_env(): tl.Env
   local config = self._server_state.config
   asserts.is_not_nil(config)

   -- applying the config to the env adds to package.path
   -- so lets reset them before doing that
   package.path = init_path
   package.cpath = init_cpath

   local env, errs = self:_init_env_from_config(config)

   if errs ~= nil and #errs > 0 then
      logger:debug("Loaded env with errors:\n%s", errs)
   end

   return env
end

function EnvUpdater:_update_env_on_changes()
   local required_delay_without_saves_sec = 0.1

   while true do
      self._change_detected:await()
      self._change_detected:unset()

      -- Full env updates can be costly for large projects, and it is common for many
      -- documents to be saved all at once, so delay slightly so we just perform one
      -- env update
      while true do
         lusc.await_sleep(required_delay_without_saves_sec)
         if self._change_detected.is_set then
            logger:debug("Detected consecutive change events, waiting again...")
            self._change_detected:unset()
         else
            logger:debug("Successfully waited for buffer time. Now updating env...")
            break
         end
      end

      logger:debug("Now updating env...")
      local start_time = uv.hrtime()
      -- decided on the old env, whose loaded modules record the dependencies
      local affected = self:_affected_documents(self._changed)
      self._changed = {}
      local env = self:_generate_env()
      self._server_state:set_env(env)
      local elapsed_time_ms = (uv.hrtime() - start_time) / 1e6
      logger:debug("Completed env update in %f ms", elapsed_time_ms)

      -- Every document's semantic data referred to the old env, so all caches
      -- go. Only documents whose inputs changed are re-checked now: the
      -- diagnostics published for the others are still correct (same text,
      -- same dependencies), and their next request re-checks them on demand.
      for path, doc in pairs(self._document_manager.docs) do
         doc:clear_cache()
         if affected[path] then
            doc:process_and_publish_results()
         end
      end
      self._type_baseline = self:type_count()
      self._env_rebuilds = self._env_rebuilds + 1
   end
end

-- Settings from tlconfig.lua `externals.teal_language_server`.
function EnvUpdater:_setting(name: string, default: number): number
   local externals = (self._server_state.config or {}).externals
   local ours = externals and (externals as {string:any}).teal_language_server
   local value = type(ours) == "table" and (ours as {string:any})[name]
   if type(value) == "number" and value as number >= 0 then
      return value as number
   end
   return default
end

-- Number of entries in the shared type report. Every re-check of a document
-- adds entries for the new type objects it creates, so this grows while editing.
function EnvUpdater:type_count(): integer
   local env = self._server_state:get_env()
   if env == nil or env.reporter == nil then
      return 0
   end
   return env.reporter.next_num
end

function EnvUpdater:get_stats(): {string:any}
   local env = self._server_state:get_env()
   return {
      documentChecks = Document.check_count(),
      typeCount = self:type_count(),
      typeBaseline = self._type_baseline,
      loadedOrder = env and #env.loaded_order or 0,
      envRebuilds = self._env_rebuilds,
   }
end

-- Rebuilds the env (fresh type report) once editing has grown the report by
-- more than `type_report_limit` entries since the last build.
function EnvUpdater:_check_type_report_growth()
   local limit = self:_setting("type_report_limit", 50000)
   local growth = self:type_count() - self._type_baseline
   if growth > limit then
      logger:info("Type report grew by %d entries (limit %d); scheduling env rebuild", growth, limit)
      self:schedule_env_update()
   end
end

-- Files (absolute) a document depends on, directly or through the modules
-- it requires: tl's Result.dependencies lists direct requires only, and the
-- results of required modules are in env.loaded.
function EnvUpdater:dependency_closure(doc: Document): {string:boolean}
   local env = self._server_state:get_env()
   local loaded_by_path: {string:tl.Result} = {}
   for file, result in pairs(env.loaded) do
      loaded_by_path[self._server_state:absolute_path(file)] = result
   end
   local out: {string:boolean} = {}
   local stack: {string} = doc:get_dependency_files()
   while #stack > 0 do
      local file = table.remove(stack)
      if not out[file] then
         out[file] = true
         local result = loaded_by_path[file]
         for _, dep in pairs(result and result.dependencies or {}) do
            table.insert(stack, self._server_state:absolute_path(dep))
         end
      end
   end
   return out
end

-- Open documents whose inputs changed: the document itself, or a file it
-- depends on (transitively). Globals declared by a module are visible
-- env-wide; a document that uses such a global without requiring the module
-- is not detected here (it is re-checked on its next request).
function EnvUpdater:_affected_documents(changed: {string:boolean}): {string:boolean}
   local out: {string:boolean} = {}
   if next(changed) == nil then
      return out
   end
   for path, doc in pairs(self._document_manager.docs) do
      if changed[path] then
         out[path] = true
      else
         for dep in pairs(self:dependency_closure(doc)) do
            if changed[dep] then
               out[path] = true
               break
            end
         end
      end
   end
   return out
end

-- Documents that import the changed module, directly or through other
-- modules, were checked against its previous text; rebuilding the env makes
-- them see the open (possibly unsaved) buffer.
function EnvUpdater:refresh_dependents(path: string)
   for other_path, doc in pairs(self._document_manager.docs) do
      if other_path ~= path and self:dependency_closure(doc)[path] then
         logger:debug("%s has dependents among open documents - enqueuing env update", path)
         self:schedule_env_update(path)
         return
      end
   end
end

-- Analyzes a document and publishes its diagnostics now.
function EnvUpdater:analyze_now(doc: Document)
   self._pending_analysis[doc.uri.path] = nil
   doc:process_and_publish_results()
   self:refresh_dependents(doc.uri.path)
   self:_check_type_report_growth()
end

-- Debounced analysis after an edit: waits `diagnostics_delay_ms` (default 150)
-- and publishes only if no newer edit arrived meanwhile. Requests do not wait
-- for this: they type check the current text on demand.
function EnvUpdater:schedule_analysis(doc: Document)
   local path = doc.uri.path
   local version = doc.version
   self._pending_analysis[path] = version
   local delay = self:_setting("diagnostics_delay_ms", 150) / 1000
   self._root_nursery:start_soon(function()
      if delay > 0 then
         lusc.await_sleep(delay)
      end
      if self._pending_analysis[path] ~= version then
         -- superseded by a newer edit
         return
      end
      local current = self._document_manager.docs[path]
      if current == nil or current.version ~= version then
         self._pending_analysis[path] = nil
         return
      end
      self:analyze_now(current)
   end)
end

-- Schedules a (debounced) env rebuild. `changed_path` is a file whose text
-- changed; the open documents depending on it are re-checked after the
-- rebuild.
function EnvUpdater:schedule_env_update(changed_path?: string)
   if changed_path then
      self._changed[changed_path] = true
   end
   self._change_detected:set()
end

-- Makes module resolution read open documents from their editor buffers, so
-- importers see unsaved edits. tl looks `search_module` up on its module table
-- at require time, so wrapping it here covers every require it performs.
function EnvUpdater:_install_open_document_overlay()
   local original = tl.search_module
   tl.search_module = function(module_name: string, search_all: boolean): string, FILE, {string}
      local found, fd, tried = original(module_name, search_all)
      if found then
         local content = self._document_manager:open_content(self._server_state:absolute_path(found))
         if content then
            if fd then
               fd:close()
            end
            logger:debug("Resolved module %s to open document %s", module_name, found)
            return found, (setmetatable({ content = content }, { __index = StringFile }) as any) as FILE, tried
         end
      end
      return found, fd, tried
   end
end

function EnvUpdater:initialize()
   local root = self._server_state.teal_project_root_dir.value
   local lua_bin = lua_env.find_lua_bin(root)
   logger:info("Using lua binary for env discovery: %s", lua_bin)
   local discovered_user_path, discovered_user_cpath = lua_env.discover_paths(lua_bin)
   if discovered_user_path then
      init_path = dedup_path(init_path .. ";" .. discovered_user_path)
      logger:info("Discovered user lua path: %s", discovered_user_path)
   end

   if discovered_user_cpath then
      init_cpath = dedup_path(init_cpath .. ";" .. discovered_user_cpath)
      logger:info("Discovered user lua cpath: %s", discovered_user_cpath)
   end

   self:_install_open_document_overlay()

   local env = self:_generate_env()
   self._server_state:set_env(env)
   self._type_baseline = self:type_count()

   self._root_nursery:start_soon(function()
      self:_update_env_on_changes()
   end)
end

class.setup(EnvUpdater, "EnvUpdater")
return EnvUpdater
