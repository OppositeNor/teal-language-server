local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local package = _tl_compat and _tl_compat.package or package; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local _module_name = "analysis.env_updater"


local DocumentManager = require("teal_language_server.analysis.document_manager")
local Document = require("teal_language_server.analysis.document")
local lua_env = require("teal_language_server.analysis.lua_env")
local lusc = require("lusc")
local ServerState = require("teal_language_server.server_state")
local tl = require("tl")
local uv = require("luv")
local asserts = require("teal_language_server.util.asserts")
local logging = require("teal_language_server.logging")
local class = require("teal_language_server.util.class")

local logger = logging.get_logger(_module_name)

local init_path = package.path
local init_cpath = package.cpath

local function dedup_path(path_str)
   local seen = {}
   local result = {}


   for entry in path_str:gmatch("[^;]+") do
      if not seen[entry] then
         seen[entry] = true
         table.insert(result, entry)
      end
   end
   return table.concat(result, ";")
end



local StringFile = {}



function StringFile:read(_fmt)
   local c = self.content
   self.content = nil
   return c
end

function StringFile:close()
   return true
end

local EnvUpdater = {}

















function EnvUpdater:__init(server_state, root_nursery, document_manager)
   asserts.is_not_nil(document_manager)

   self._change_detected = lusc.new_sticky_event()
   self._pending_analysis = {}
   self._type_baseline = 0
   self._env_rebuilds = 0
   self._server_state = server_state
   self._root_nursery = root_nursery
   self._document_manager = document_manager
end

function EnvUpdater:_init_env_from_config(cfg)
   local function ivalues(t)
      local i = 0
      return function()
         i = i + 1
         return t[i]
      end
   end

   local path_separator = package.config:sub(1, 1)
   local shared_lib_ext = package.cpath:match("(%.%w+)%s*$") or ".so"

   local function prepend_to_lua_path(path_str)
      if path_str:sub(-1) == path_separator then
         path_str = path_str:sub(1, -2)
      end

      path_str = path_str .. path_separator

      package.path = path_str .. "?.lua;" ..
      path_str .. "?" .. path_separator .. "init.lua;" ..
      package.path

      package.cpath = path_str .. "?." .. shared_lib_ext .. ";" ..
      package.cpath
   end

   local function init_teal_env(gen_compat, gen_target, env_def)
      local opts = {
         defaults = {
            gen_compat = gen_compat,
            gen_target = gen_target,
         },
         predefined_modules = { env_def },
      }

      local env = tl.new_env(opts)
      env.report_types = true

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

function EnvUpdater:_generate_env()
   local config = self._server_state.config
   asserts.is_not_nil(config)



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
      local env = self:_generate_env()
      self._server_state:set_env(env)
      local elapsed_time_ms = (uv.hrtime() - start_time) / 1e6
      logger:debug("Completed env update in %f ms", elapsed_time_ms)

      for _, doc in pairs(self._document_manager.docs) do
         doc:clear_cache()
         doc:process_and_publish_results()
      end
      self._type_baseline = self:type_count()
      self._env_rebuilds = self._env_rebuilds + 1
   end
end


function EnvUpdater:_setting(name, default)
   local externals = (self._server_state.config or {}).externals
   local ours = externals and (externals).teal_language_server
   local value = type(ours) == "table" and (ours)[name]
   if type(value) == "number" and value >= 0 then
      return value
   end
   return default
end



function EnvUpdater:type_count()
   local env = self._server_state:get_env()
   if env == nil or env.reporter == nil then
      return 0
   end
   return env.reporter.next_num
end

function EnvUpdater:get_stats()
   local env = self._server_state:get_env()
   return {
      typeCount = self:type_count(),
      typeBaseline = self._type_baseline,
      loadedOrder = env and #env.loaded_order or 0,
      envRebuilds = self._env_rebuilds,
   }
end



function EnvUpdater:_check_type_report_growth()
   local limit = self:_setting("type_report_limit", 50000)
   local growth = self:type_count() - self._type_baseline
   if growth > limit then
      logger:info("Type report grew by %d entries (limit %d); scheduling env rebuild", growth, limit)
      self:schedule_env_update()
   end
end



function EnvUpdater:refresh_dependents(path)
   if #self._document_manager:dependents_of(path) > 0 then
      logger:debug("%s has dependents among open documents - enqueuing env update", path)
      self:schedule_env_update()
   end
end


function EnvUpdater:analyze_now(doc)
   self._pending_analysis[doc.uri.path] = nil
   doc:process_and_publish_results()
   self:refresh_dependents(doc.uri.path)
   self:_check_type_report_growth()
end




function EnvUpdater:schedule_analysis(doc)
   local path = doc.uri.path
   local version = doc.version
   self._pending_analysis[path] = version
   local delay = self:_setting("diagnostics_delay_ms", 150) / 1000
   self._root_nursery:start_soon(function()
      if delay > 0 then
         lusc.await_sleep(delay)
      end
      if self._pending_analysis[path] ~= version then

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

function EnvUpdater:schedule_env_update()
   self._change_detected:set()
end




function EnvUpdater:_install_open_document_overlay()
   local original = tl.search_module
   tl.search_module = function(module_name, search_all)
      local found, fd, tried = original(module_name, search_all)
      if found then
         local content = self._document_manager:open_content(self._server_state:absolute_path(found))
         if content then
            if fd then
               fd:close()
            end
            logger:debug("Resolved module %s to open document %s", module_name, found)
            return found, (setmetatable({ content = content }, { __index = StringFile })), tried
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
