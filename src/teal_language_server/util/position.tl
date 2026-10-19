-- Conversions between the column units used inside the server and the ones
-- used on the wire.
--
--   * tl (lexer/parser/type report): 1-based line, 1-based *byte* column
--   * tree-sitter:                   0-based row,  0-based *byte* column
--   * LSP (default encoding):        0-based line, 0-based *UTF-16 code unit* column
--
-- The helpers here operate on a single line of text and never use the `utf8`
-- library so they work on every Lua version the server supports (5.1 - 5.4).
-- Malformed UTF-8 is treated byte-by-byte (one code unit per byte) rather than
-- raising, since editors may hand us partially-typed text.

local record position
end

-- Returns the length in bytes of the UTF-8 sequence starting with `b` and the
-- number of UTF-16 code units the encoded code point occupies.
local function sequence_info(b: integer): integer, integer
   if b < 0x80 then
      return 1, 1
   elseif b >= 0xF0 and b < 0xF8 then
      return 4, 2
   elseif b >= 0xE0 then
      return 3, 1
   elseif b >= 0xC0 then
      return 2, 1
   end
   -- stray continuation byte
   return 1, 1
end

-- Converts a 0-based byte column on `line` to a 0-based UTF-16 column.
-- Columns past the end of the line are extended by one unit per byte so that
-- end-of-line / end-of-file positions stay monotonic.
function position.byte_to_utf16(line: string, byte_col: integer): integer
   if byte_col <= 0 then
      return 0
   end
   local len = #line
   local i = 1
   local units = 0
   while i <= byte_col and i <= len do
      local size, width = sequence_info(line:byte(i))
      if i + size - 1 > byte_col then
         -- byte_col points into the middle of a code point; round down
         break
      end
      i = i + size
      units = units + width
   end
   if byte_col > len then
      units = units + (byte_col - len)
   end
   return units
end

-- Converts a 0-based UTF-16 column on `line` to a 0-based byte column. A
-- column that falls inside a surrogate pair rounds down to the start of the
-- code point; columns past the end of the line are clamped to the line length.
function position.utf16_to_byte(line: string, utf16_col: integer): integer
   if utf16_col <= 0 then
      return 0
   end
   local len = #line
   local i = 1
   local units = 0
   while i <= len do
      local size, width = sequence_info(line:byte(i))
      if units + width > utf16_col then
         break
      end
      units = units + width
      i = i + size
   end
   if i - 1 > len then
      return len
   end
   return i - 1
end

-- Splits `text` into lines on "\n" (a trailing "\r" is kept as part of the
-- line, which matches how LSP clients count columns on CRLF files).
function position.split_lines(text: string): {string}
   local lines: {string} = {}
   local start = 1
   while true do
      local nl = text:find("\n", start, true)
      if not nl then
         table.insert(lines, text:sub(start))
         break
      end
      table.insert(lines, text:sub(start, nl - 1))
      start = nl + 1
   end
   return lines
end

-- Reads a single 0-based line from a file on disk. Used for converting
-- positions in files that are not open in the editor (e.g. go-to-definition
-- targets). Returns "" if the file or line cannot be read.
function position.read_file_line(path: string, line: integer): string
   local fd = io.open(path, "rb")
   if not fd then
      return ""
   end
   local n = 0
   for l in fd:lines() do
      if n == line then
         fd:close()
         return l
      end
      n = n + 1
   end
   fd:close()
   return ""
end

return position
