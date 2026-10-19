local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local debug = _tl_compat and _tl_compat.debug or debug; local table = _tl_compat and _tl_compat.table or table; local xpcall = _tl_compat and _tl_compat.xpcall or xpcall; local _module_name = "lsp.events_manager"

local lsp = require("teal_language_server.lsp.protocol")
local LspReaderWriter = require("teal_language_server.lsp.reader_writer")
local lusc = require("lusc")
local asserts = require("teal_language_server.util.asserts")
local logging = require("teal_language_server.logging")
local class = require("teal_language_server.util.class")

local logger = logging.get_logger(_module_name)

local LspEventsManager = {}














function LspEventsManager:__init(root_nursery, lsp_reader_writer)
   asserts.is_not_nil(root_nursery)
   asserts.is_not_nil(lsp_reader_writer)

   self._handlers = {}
   self._queue = {}
   self._queue_ready = lusc.new_sticky_event()
   self._cancelled = {}
   self._lsp_reader_writer = lsp_reader_writer
   self._root_nursery = root_nursery
end

function LspEventsManager:set_handler(method, handler)
   asserts.that(self._handlers[method] == nil)
   self._handlers[method] = handler
end





function LspEventsManager:_trigger(method, params, id)
   logger:info("Received request from client for method %s", method)

   local is_request = id ~= nil
   local handler = self._handlers[method]

   if handler == nil then
      if is_request then
         logger:warning("No handler found for request with method %s", method)
         self._lsp_reader_writer:send_rpc_error(id, "MethodNotFound", "Unhandled method " .. tostring(method))
      else
         logger:debug("Ignoring notification with method %s", method)
      end
      return
   end

   local responses_before = self._lsp_reader_writer:get_response_count()

   local ok, err = xpcall(
   function() handler(params, id) end,
   debug.traceback)

   local responded = self._lsp_reader_writer:get_response_count() > responses_before

   if ok then
      logger:debug("Successfully handled request with method %s", method)
      if is_request and not responded then
         logger:warning("Handler for %s returned without responding; sending null result", method)
         self._lsp_reader_writer:send_rpc(id, nil)
      end
   else
      if lusc.is_cancelled_error(err) then
         error(err, 0)
      end
      logger:error("Error in handler for request with method %s: %s", method, err)
      if is_request and not responded then
         self._lsp_reader_writer:send_rpc_error(id, "InternalError", "Internal error while handling " .. tostring(method))
      end
   end
end

function LspEventsManager:_receive_initialize_request()
   local initialize_data = self._lsp_reader_writer:receive_rpc()

   asserts.is_not_nil(initialize_data)

   asserts.that(initialize_data.method ~= nil, "No method in initial request")
   asserts.that(initialize_data.method == "initialize", "Initial method was not 'initialize'")

   logger:trace("Received initialize request from client with data: %s", initialize_data)

   self:_trigger(
   "initialize", initialize_data.params, initialize_data.id)
end




function LspEventsManager:_read_loop()
   while true do





      local ok, data = xpcall(
      function() return self._lsp_reader_writer:receive_rpc() end,
      debug.traceback)
      if not ok and lusc.is_cancelled_error(data) then


         error(data, 0)
      end
      if ok and data and data.method then
         if data.method == "$/cancelRequest" then
            local params = data.params
            if params and params.id ~= nil then
               self._cancelled[params.id] = true
            end
         else
            table.insert(self._queue, data)
            self._queue_ready:set()
         end
      end
   end
end



function LspEventsManager:_process_loop()
   while true do
      self._queue_ready:await()
      self._queue_ready:unset()
      while #self._queue > 0 do
         local data = table.remove(self._queue, 1)
         local id = data.id
         if id ~= nil and self._cancelled[id] then
            self._cancelled[id] = nil
            logger:debug("Request %s (%s) was cancelled before it was handled", tostring(id), tostring(data.method))
            self._lsp_reader_writer:send_rpc_error(id, "RequestCancelled", "Request cancelled")
         else
            self:_trigger(data.method, data.params, id)
         end
         lusc.await_sleep(0)
      end

      self._cancelled = {}
   end
end

function LspEventsManager:initialize()
   self._root_nursery:start_soon(function()

      self:_receive_initialize_request()

      self._root_nursery:start_soon(function()
         self:_process_loop()
      end)
      self:_read_loop()
   end)
end

class.setup(LspEventsManager, "LspEventsManager")
return LspEventsManager
