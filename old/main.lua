local vc = require("virt_composer")
local capi = require("char_api")

local fontset = nil

function test_init()
	fontset = capi.load_font_set(42)
end

--[[ TODO: Add imports into code ]]
--[[ TODO: Add the ast into this and make functions that will let us draw the ast ]]
--[[ TODO: Figure out where this drawing will stay in conjunction with the drawing spaces ]]

local function draw_ast_node(node)
end

local increment = 1
local i = 0
function test_draw()
	if i == 10 then
		increment = increment + 1
		if increment > 248 then
			increment = 1
		end
		i = 0
	end
	i = i + 1

	local c = capi.chars[increment]
	-- print(c.desc)
	capi.draw_char(fontset, c, 0, 0)
end
