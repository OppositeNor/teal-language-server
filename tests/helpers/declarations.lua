-- A small declaration module (`.d.tl`) describing an API implemented outside
-- Teal (e.g. in C), plus a script that uses it. Shared by the tests of
-- declaration-file support.

local declarations = {}

declarations.SHAPES_DTL = table.concat({
    "-- Declarations for a module implemented outside Teal.", -- 0
    "local record shapes",                                    -- 1
    "   enum Color",                                          -- 2
    '      "red"',                                            -- 3
    '      "green"',                                          -- 4
    '      "blue"',                                           -- 5
    "   end",                                                 -- 6
    "",                                                       -- 7
    "   record Style",                                        -- 8
    "      color: Color",                                     -- 9
    "      width: integer",                                   -- 10
    "   end",                                                 -- 11
    "",                                                       -- 12
    "   record Point",                                        -- 13
    "      x: number",                                        -- 14
    "      y: number",                                        -- 15
    "   end",                                                 -- 16
    "",                                                       -- 17
    "   record Path",                                         -- 18
    "      move_to: function(self, p: Point): Path",          -- 19
    "      line_to: function(self, p: Point): Path",          -- 20
    "      close: function(self): Path",                      -- 21
    "   end",                                                 -- 22
    "",                                                       -- 23
    "   record Canvas",                                       -- 24
    "      new_path: function(self, name: string, style: Style): Path", -- 25
    "      draw: function(self, path: Path, callback: function(Path))",  -- 26
    "      flush: function(self): boolean",                   -- 27
    "   end",                                                 -- 28
    "",                                                       -- 29
    "   new: function(): Canvas",                             -- 30
    "end",                                                    -- 31
    "",                                                       -- 32
    "return shapes",                                          -- 33
}, "\n")

declarations.MAIN_TL = table.concat({
    'local shapes = require("shapes")',                                    -- 0
    "",                                                                    -- 1
    "local canvas = shapes.new()",                                         -- 2
    'local path = canvas:new_path("outline", { color = "red", width = 2 })', -- 3
    "canvas:draw(path, function(p: shapes.Path)",                          -- 4
    "   p:move_to({ x = 0, y = 0 }):line_to({ x = 1, y = 1 })",            -- 5
    "end)",                                                                -- 6
    "print(canvas:flush())",                                               -- 7
}, "\n")

return declarations
