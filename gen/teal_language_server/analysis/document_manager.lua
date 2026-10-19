local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local table = _tl_compat and _tl_compat.table or table; local _module_name = "analysis.document_manager"


local ServerState = require("teal_language_server.server_state")
local LspReaderWriter = require("teal_language_server.lsp.reader_writer")
local Uri = require("teal_language_server.util.uri")
local Document = require("teal_language_server.analysis.document")
local asserts = require("teal_language_server.util.asserts")
local class = require("teal_language_server.util.class")
local logging = require("teal_language_server.logging")

local logger = logging.get_logger(_module_name)

local DocumentManager = {}









function DocumentManager:__init(lsp_reader_writer, server_state)
   asserts.is_not_nil(lsp_reader_writer)
   asserts.is_not_nil(server_state)

   self._docs = {}
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
end

function DocumentManager:open(uri, content, version)
   if uri == nil then
      logger:error("Invalid Uri, will not be able to open document")
      return
   end
   local doc = Document(uri, content, version, self._lsp_reader_writer, self._server_state)
   self._docs[uri.path] = doc
   return doc
end

function DocumentManager:close(uri)
   if uri == nil then
      logger:error("Invalid Uri, will not be able to close document")
      return
   end
   self._docs[uri.path] = nil
end

function DocumentManager:get(uri)
   if uri == nil then
      logger:error("Invalid Uri, will not be able to get document")
      return
   end
   return self._docs[uri.path]
end


function DocumentManager:dependents_of(path)
   local out = {}
   for doc_path, doc in pairs(self._docs) do
      if doc_path ~= path then
         for _, dep in ipairs(doc:get_dependency_files()) do
            if dep == path then
               table.insert(out, doc)
               break
            end
         end
      end
   end
   return out
end


function DocumentManager:open_content(path)
   local doc = self._docs[path]
   return doc and doc.content
end

class.setup(DocumentManager, "DocumentManager", {
   getters = {
      docs = function(self)
         return self._docs
      end,
   },
})
return DocumentManager
