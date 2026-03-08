vc = require("virt_composer")

-- obs: I can draw a small dot for the specified mode of selection, thus
-- letting the user select the term of choice

-- obs: There needs not be any complicated ctrl+z because the steps are allways above, so
-- a ctrl+z is practically: remove the current eq-state and goto prev one
--[[ 
So How this is supposed to work:

TODO: Add functions for diverse types.
TODO: Add functions to do diverse things with types
TODO: Remember that inheritance must be implemented
]]--


function main() 
    print("Hello from Lua!")
    print(vc.c:generate_latex())
    print(vc.d:generate_latex())
    print(vc.e1:generate_latex())
    print(vc.e2:generate_latex())
    print(vc.e2)
    print(vc.l1)
    print(vc.l1:generate_latex())
    print(vc.M:generate_latex())
    -- print(tostring(vc.a))
    -- print(vc.b)
    -- print(vc.n1)
    -- print(vc.c)
    -- print(vc.AST_NODE_ADDITION)
end
