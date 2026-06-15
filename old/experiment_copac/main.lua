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

-- TODO: !!! VERY IMPORTANT !!! Pack all variables in some sort of self-node, that is such that
-- variables inside expressions can have mobile occurences, else you couldn't differentiate from
-- for axample the two `a` in: ab+ac

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
    ch1 = vc.e2:get_child(1)
    vc.e2:push_child(ch1:create_copy())
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

function vref(var)
    local vr = vc.create_ast_node(vc.AST_NODE_SHELL)
    vr:push_child(var)
    return vr
end

function test_work()
    local a = vc.create_ast_var("a")
    local b = vc.create_ast_var("b")
    local c = vc.create_ast_var("c")
    local n_10 = vc.create_ast_int(10)
    local abc = vc.create_ast_node(vc.AST_NODE_MUL)
    abc:push_child(vref(a))
    abc:push_child(vref(b))
    abc:push_child(vref(c))

    local ab = vc.create_ast_node(vc.AST_NODE_MUL)
    ab:push_child(vref(a))
    ab:push_child(vref(b))

    local ac = vc.create_ast_node(vc.AST_NODE_MUL)
    ac:push_child(vref(a))
    ac:push_child(vref(c))

    local bc = vc.create_ast_node(vc.AST_NODE_MUL)
    bc:push_child(vref(b))
    bc:push_child(vref(c))

    -- I is for paranthesis and
    -- _ is for addition

    local ab_ac_bc = vc.create_ast_node(vc.AST_NODE_ADD)
    ab_ac_bc:push_child(ab)
    ab_ac_bc:push_child(ac)
    ab_ac_bc:push_child(bc)

    local aIab_ac_bcI = vc.create_ast_node(vc.AST_NODE_MUL)
    aIab_ac_bcI:push_child(vref(a))
    aIab_ac_bcI:push_child(ab_ac_bc)

    -- Transform Name:
    -- Drag Term out
    -- ===============
    -- 
    -- Example: having a(ab+ac+bc) and bc. I want to drag ac out to get: a(ab+ac)+abc  
    -- 
    -- So the steps necesary are:
    -- 1. First we need to specify the source experssion, in our case bc and an destination
    --    expression with destination position as well, so a pair of src=bc dst=(aIab_acI, 2nd child)
    -- 2. As you can see we don't exactly have an aIab_acI, but we can get one, by modifying the
    --    destination node
    -- 3. So we want to do the following: pop the bc expression out of the aIab_bc_acI expression:
    --    As such, not only can we collect the necesary factors along the way and form the expression
    --    at end, but we also get our experssion in the desired form
    -- OBS: We need to `pop` the expression bc out only to the common ancestor, we don't really care
    --      further away
    --      Now, the `pop` command will be expression specific, from some it will not make sense to
    --      `pop` the src so in that case we need to somehow signal that we failed and clean-up
    -- TODO: make sure objects get cleaned up after they die in lua, not to forever use space

    print("# Start of operation:")
    local copy = aIab_ac_bcI:create_copy()

    print("## The copy: ")
    print( copy:generate_latex())

    print("## The parent:")
    local parent, index_in_parent = table.unpack(bc:get_parent(0))
    print(index_in_parent, parent:generate_latex())

    print("## The grand-parent:")
    local gparent, index_in_gparent = table.unpack(parent:get_parent(0))
    print(index_in_gparent, gparent:generate_latex())

    print("## The no-parent")
    local nparent, index_in_nparent = table.unpack(gparent:get_parent(0))
    print(index_in_nparent, nparent)

    --[[ so this exemplifies how you would create a `path` from the selection to the root ]]
    print("After erasure:")
    parent:erase_child(index_in_parent)
    print(aIab_ac_bcI:generate_latex())
    print("Copy after erasure:")
    print(copy:generate_latex())

    a(ab + ac + bc)


    local common = common_ancestor(ab, aIab_ac_bcI)
    -- TODO: figure this out:

    -- local parent_of_bc, index = table.unpack(bc:get_parent(0))
    -- if parent_of_bc:has_flags(vc.AST_NODE_ADD)
    -- while true do
    --     local parent_of_bc, index = table.unpack(bc:get_parent(0))
    --     -- assert(parre) if not parent_of_bc then error_out() end

    --     if parent_of_bc:selfp() == common:selfp() then
    --         break
    --     end

    --     if parent_of_bc:has_flags(vc.AST_NODE_ADD) then
    --         -- we just delete the child at pos
    --         parent_of_bc:erase_child(index)
    --     else if parent_of_bc:has_flags then

    --     else

    --     end
    -- end

    print(common_ancestor(ab, aIab_ac_bcI):generate_latex())

    print(aIab_ac_bcI:generate_latex())

    local parent_of_bc, location = table.unpack(bc:get_parent(0))
    print(string.format("child[%d]: %s", location, parent_of_bc:generate_latex()))

    local parent_of_parent_of_bc, location2 = table.unpack(parent_of_bc:get_parent(0))
    print(string.format("child[%d]: %s", location2, parent_of_parent_of_bc:generate_latex()))

end

function main() 
    print("Hello from Lua!")
    -- test_stuff()
    test_work()

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
