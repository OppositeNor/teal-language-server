local _module_name = "lsp.events_manager"

local lsp <const> = require("teal_language_server.lsp.protocol")
local LspReaderWriter <const> = require("teal_language_server.lsp.reader_writer")
local lusc <const> = require("lusc")
local asserts <const> = require("teal_language_server.util.asserts")
local logging <const> = require("teal_language_server.logging")
local class <const> = require("teal_language_server.util.class")

local logger = logging.get_logger(_module_name)

local record LspEventsManager
   _lsp_reader_writer: LspReaderWriter
   _root_nursery:lusc.Nursery

   _handlers:{lsp.Method.Name: function(lsp.Method.Params, integer)}

   -- messages read from the client but not yet dispatched
   _queue: {{string:any}}
   _queue_ready: lusc.StickyEvent
   -- ids of queued requests the client cancelled ($/cancelRequest)
   _cancelled: {any:boolean}

   metamethod __call: function(self: LspEventsManager, root_nursery:lusc.Nursery, lsp_reader_writer:LspReaderWriter): LspEventsManager
end

function LspEventsManager:__init(root_nursery:lusc.Nursery, lsp_reader_writer:LspReaderWriter)
   asserts.is_not_nil(root_nursery)
   asserts.is_not_nil(lsp_reader_writer)

   self._handlers = {}
   self._queue = {}
   self._queue_ready = lusc.new_sticky_event()
   self._cancelled = {}
   self._lsp_reader_writer = lsp_reader_writer
   self._root_nursery = root_nursery
end

function LspEventsManager:set_handler(method:lsp.Method.Name, handler:function(lsp.Method.Params, integer))
   asserts.that(self._handlers[method] == nil)
   self._handlers[method] = handler
end

-- Dispatches one message. Requests (messages with an id) are guaranteed exactly
-- one response: the handler's own, an InternalError if the handler raised, a
-- MethodNotFound for unknown methods, or a null result if the handler returned
-- without responding. Notifications never get a response.
function LspEventsManager:_trigger(method:lsp.Method.Name, params:lsp.Method.Params, id:integer)
   logger:info("Received request from client for method %s", method)

   local is_request <const> = id ~= nil
   local handler <const> = self._handlers[method]

   if handler == nil then
      if is_request then
         logger:warning("No handler found for request with method %s", method)
         self._lsp_reader_writer:send_rpc_error(id, "MethodNotFound", "Unhandled method " .. tostring(method))
      else
         logger:debug("Ignoring notification with method %s", method)
      end
      return
   end

   local responses_before <const> = self._lsp_reader_writer:get_response_count()

   local ok, err = xpcall(
      function() handler(params, id) end,
      debug.traceback as function) as (boolean, string)

   local responded <const> = self._lsp_reader_writer:get_response_count() > responses_before

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
      "initialize", initialize_data.params as lsp.Method.Params, initialize_data.id as integer)
end

-- Reads messages from the client into the queue. `$/cancelRequest` is handled
-- here, so a cancellation that arrives while earlier messages are still being
-- processed takes effect before the cancelled request is dispatched.
function LspEventsManager:_read_loop()
   while true do
      -- Must go through xpcall (not pcall): receive_rpc yields while awaiting
      -- stdin data, and on Lua 5.1 only xpcall is patched (see bin/teal-language-server)
      -- to allow yielding across this C-call boundary. A plain pcall here breaks
      -- the read loop on every iteration under Lua 5.1, so the server never
      -- processes another message after `initialize`.
      local ok, data = xpcall(
         function(): {string:any} return self._lsp_reader_writer:receive_rpc() end,
         debug.traceback as function) as (boolean, {string:any})
      if not ok and lusc.is_cancelled_error(data) then
         -- Let shutdown's nursery cancellation actually unwind this task,
         -- instead of catching it here and retrying forever.
         error(data, 0)
      end
      if ok and data and data.method then
         if data.method == "$/cancelRequest" then
            local params = data.params as {string:any}
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

-- Dispatches queued messages in order, yielding between messages so the
-- reader can pick up input (including cancellations) that arrived meanwhile.
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
            self._lsp_reader_writer:send_rpc_error(id as integer, "RequestCancelled", "Request cancelled")
         else
            self:_trigger(data.method as lsp.Method.Name, data.params as lsp.Method.Params, id as integer)
         end
         lusc.await_sleep(0)
      end
      -- a cancellation for a request that was already answered is moot
      self._cancelled = {}
   end
end

function LspEventsManager:initialize()
   self._root_nursery:start_soon(function()
      -- Initialize method must be first
      self:_receive_initialize_request()

      self._root_nursery:start_soon(function()
         self:_process_loop()
      end)
      self:_read_loop()
   end)
end

class.setup(LspEventsManager, "LspEventsManager")
return LspEventsManager
