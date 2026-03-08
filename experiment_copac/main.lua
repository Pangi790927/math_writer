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

TODO: test those
VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, has_flags, vc::bm_t<ast_flags_e>);
VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, get_op);
VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, num_childs);
VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, push_child, vc::ref_t<ast_node_t>);
VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, pop_child);
VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, get_child, int);
VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, set_child, int, vc::ref_t<ast_node_t>);


]]--

function test_stuff()
    print("# Started Testing Stuff")

    print("## Testing the op")
    print(vc.a.m_op)
    print(vc.AST_NODE_VAR)
    print(vc.AST_NODE_VAR == vc.a.m_op)

    print("## Testing flags:")
    print(vc.e2.m_flags)
    print(vc.AST_FLAG_FN_CALL_BUILTIN)
    print(vc.AST_FLAG_LIST_VERT_SUBSTACK)
    print(vc.e2:has_flags(vc.AST_FLAG_FN_CALL_BUILTIN))
    print(vc.e2:has_flags(vc.AST_FLAG_LIST_VERT_SUBSTACK))

    print("## Testing childs:")
    print("------------------")
    print(vc.e2)
    print("------------------")
    print("num_childs: ", vc.e2:num_childs())
    print("------------------")
    print(vc.e2:get_child(0))
    vc.e2:push_child(vc.e2:get_child(1))
    print("------------------")
    print(vc.e2)
    vc.e2:pop_child()
    print("------------------")
    print(vc.e2)
    print("------------------")
    vc.e2:set_child(1, vc.a)
    print(vc.e2)
    print("------------------")

    print("## Testing generate_latex")
    print(vc.e2:generate_latex())
    print(vc.M:generate_latex())

    print("## test: test_tuple_return")
    print(table.unpack(vc.a:test_tuple_return()))

    print("# Finished Testing Stuff")
end

function main() 
    print("Hello from Lua!")
    test_stuff()

    -- print(vc.c:generate_latex())
    -- print(vc.d:generate_latex())
    -- print(vc.e1:generate_latex())
    -- print(vc.e2:generate_latex())
    -- print(vc.e2)
    -- print(vc.l1)
    -- print(vc.l1:generate_latex())
    -- print(vc.M:generate_latex())
    -- print(tostring(vc.a))
    -- print(vc.b)
    -- print(vc.n1)
    -- print(vc.c)
    -- print(vc.AST_NODE_ADDITION)
end
