--[[ ==================================== WHAT THIS FILE OFFERS ====================================

declare(owner: string, name: string, fields, opts: table) -> shape
    Declares a container's field set and returns its shape. `owner` is
    the file that owns it and `name` is what the table is called at its
    call sites - both appear in the error, since the fix is always in
    one of the two.

shape.wrap(t)                           -> t, sealed
    THE ONE THING A CREATOR CALLS. Seals a freshly built table, which
    is why every container has exactly one creator function.

shape.owner / shape.name / shape.type_name / shape.fields
    What was declared. `type_name` is "owner.name" - the owner is part
    of the type, not decoration, since two files may reasonably call
    their container the same thing.

shape.check_name(value, what)           -> value
    ONE name against the declaration, for a value that must be one of a
    fixed set - a parse mark's status, say. The same mechanism as
    check_keys rather than a hand-written `assert(SET[x], ...)`.

shape.check_keys(t, what)               -> t
shape.check_covers(t, what)             -> t
    The two ends of "do these sets agree": every key of `t` is
    declared, and every declared name has an entry in `t`. Neither
    implies the other, and both are wanted where a second table mirrors
    the declaration.
    Every key of an ALREADY-BUILT table against the declaration - for
    an options literal, which a seal cannot police because its keys are
    present before the seal is on. nil is allowed: no options at all.

shape.is(t)                             -> boolean
shape.check(t, what)                    -> t
    Is this that container? `check` asserts it and is meant for the top
    of a function that takes one - it catches the WRONG container being
    passed, which the field seal cannot see because the names that
    overlap are all declared.

type_of(t: table)                       -> "owner.name" | nil
    Which sealed type any table is, for an error message.

all()                                   -> {shape, ...}
    Every container declared so far, so a static check can walk them
    all rather than each owner publishing its own accessor.

--- internal, not on the module table --------------------------------------------------------------
    reject
@date 2026-09-12 05:40
================================================================================================= ]]

--[[
sealed.lua - a container whose field set is declared, and fixed.

THE PROBLEM THIS SOLVES. A table that is created in one file and written from several is the one
place Lua's openness costs more than it gives: `u.bracjet = x` stores happily, reads back nil, and
nothing anywhere says the field does not exist. The bug is silent, and it is silent in the direction
that matters - the code carries on with a nil it never meant to have.

THE RULE, in the author's own terms, 2026-09-12: a declared field that was never set still reads as
nil, and an undeclared name is rejected so that "invalid table members are fixed". The table looks
exactly as it always did to every caller; only the names that were never valid change behaviour.

WHY ONE FILE AND NOT ONE METATABLE PER CONTAINER. There are already six of these - `u`, the document
state, a plugin's ctx, and the three editor box states - and the metatable is the same seventeen
lines each time. Writing it once means the error message, the read/write asymmetry and the cost
profile are decided in one place rather than drifting per container.

COST. Both metamethods fire ONLY while a key is absent: once a field has been written, reads and
writes of it bypass the metatable entirely. So the check is paid on a field's first write, and on
reads of fields a node or a box does not have - never on the ones it does.

WHAT THIS IS NOT. It does not freeze VALUES, only the set of names. It does not reach into
sub-tables: `u.bracket` is a declared field, and what is inside it is an ordinary table. And it does
not make a container private - every caller reads and writes exactly what it always did.
@date 2026-09-12 05:40
]]

local sealed = {}

--[[ Every shape declared in this process, in declaration order.

THE REASON THIS EXISTS rather than a `declared_fields()` on each owner: there are eight containers
now, and eight near-identical accessors is the duplication this file was made to remove. A static
check wants to walk all of them, and a panel that ever lists them wants the same.
@date 2026-09-12 06:25 ]]
local DECLARED = {}

--[[ The message every rejection raises.

Names the field, the container and the file that owns the declaration, because the fix is never at
the call site: it is either a typo there or a missing line in that file's field list. Level 3 so the
position reported is the CALLER's line rather than this one - the caller is what needs looking at.
@date 2026-09-12 05:40 ]]
--[[ Which sealed type a table is, or nil for anything that is not one.

THE METATABLE IS THE TYPE. Each declare() builds exactly one, so identity against it is proof of
which container a table is - no tag field to be copied by accident, and nothing a plain table can
counterfeit. This reads the name back out for an error message.
@date 2026-09-12 06:45 ]]
local TYPE_OF = setmetatable({}, {__mode = "k"})

--[[ Which sealed type a table is, as "owner.name", or nil for anything that is not one.

FOR ERROR MESSAGES, chiefly: when a check fails, saying which container arrived is most of the
diagnosis. Answers nil rather than throwing for a plain table, a nil or a number, because asking is
allowed about anything.

Weak-keyed, so a shape declared and dropped does not pin its metatable in memory. Nothing in this
project drops one, and the map should not be the reason that stays true.
@date 2026-09-12 06:45 ]]
function sealed.type_of(t)
    if type(t) ~= "table" then
        return nil
    end
    return TYPE_OF[getmetatable(t)]
end

local function reject(owner, name, key)
    error(string.format(
            "%s: `%s.%s` is not a declared field - fix the typo, or declare it in %s.lua",
            owner, name, tostring(key), owner), 3)
end

--[[ Declares a container's shape.

Called once, at file scope, beside the creator that builds the container. `fields` maps each field
name to a one-line description of what it holds - the descriptions are not used at runtime, and
that is deliberate: this table IS the documentation, so there is one list rather than a list and a
comment that can disagree with it.

Params:
    owner   the module that owns the container, as it appears in `require` - used in the error
    name    what the table is called where it is used: "u", "state", "ctx"
    fields  {field name -> one-line meaning}
    opts    optional.
            `readonly = true` refuses EVERY write, not only undeclared ones - for a container
            that is handed to somebody as input, where writing back would be a side channel
            instead of a return value. A plugin's ctx is the case this exists for.
            `array = true` lets INTEGER keys through untouched while still policing the string
            ones. An ast node is the case: `type` and `id` are its whole named surface, and its
            children are positional and unbounded, so there is nothing there to declare.

Returns a shape: `fields` as given, and `wrap`.
@date 2026-09-12 05:40 ]]
function sealed.declare(owner, name, fields, opts)
    opts = opts or {}
    local meta = {
        __index = function(_, key)
            if fields[key] == nil and not (opts.array and type(key) == "number") then
                reject(owner, name, key)
            end
            --[[ A DECLARED FIELD THAT WAS NEVER SET IS NIL, exactly as it would be on a plain
            table. That is the half of this that must not change: `u.bracket` on a letter, `radial`
            on a document with no menu open, are ordinary answers and not mistakes. ]]
            return nil
        end,
        __newindex = function(t, key, value)
            if opts.readonly then
                error(string.format("%s: `%s.%s` - %s is what a caller RECEIVES and is not "
                        .. "writable", owner, name, tostring(key), name), 3)
            end
            if fields[key] == nil and not (opts.array and type(key) == "number") then
                reject(owner, name, key)
            end
            rawset(t, key, value)
        end,
    }
    local type_name = owner .. "." .. name
    TYPE_OF[meta] = type_name

    local shape = {
        owner = owner,
        name = name,
        --[[ OWNER IS PART OF THE TYPE, not decoration: `state_doc` alone says which variable this
        is, `content.state_doc` says which container - and the two editors' states would otherwise
        be distinguishable only by a name somebody could repeat. ]]
        type_name = type_name,
        fields = fields,
        --[[ Takes the table the creator just built rather than building one itself: a creator wants
        to write its initial fields as a normal constructor expression, and those writes must happen
        BEFORE the seal is on - otherwise every one of them pays the metamethod. ]]
        wrap = function(t)
            return setmetatable(t, meta)
        end,

        --[[ Every key of an ALREADY-BUILT table, against the declaration.

        WHY A SEAL CANNOT DO THIS. Both metamethods fire only while a key is ABSENT, so a table
        that arrives fully built - an options literal written at a call site - has every key
        present before this ever sees it, misspelt ones included, and `setmetatable` after the fact
        never fires on them. That is a property of Lua, not a choice, and it is the whole reason
        this function exists beside `wrap`.

        Two files had written this loop out by hand before it was put here, which is the
        duplication this file was made to remove. Author, 2026-09-12: "what is this, why not the
        sealed?".

        Returns `t` so it can stand at the top of a function. A nil table is allowed and checks
        nothing - an absent options table is every option at its default.
        @date 2026-09-12 18:30 ]]
        check_keys = function(t, what)
            if t == nil then
                return t
            end
            if type(t) ~= "table" then
                error(string.format("%s: expected a table of options for `%s`, got %s",
                        owner, what or name, type(t)), 3)
            end
            for key in pairs(t) do
                if fields[key] == nil then
                    reject(owner, what or name, key)
                end
            end
            return t
        end,

        --[[ ONE NAME against the declaration, for a value that must be one of a fixed set.

        A declared set of names with a line each is exactly what `declare` already takes, and "is
        this one of them" is the same question `check_keys` asks of a whole table - so it is the
        same mechanism rather than a fourth hand-written `assert(SOME_TABLE[x], ...)`. There were
        four of those before this existed, each with its own wording. Author, 2026-09-12, on the
        first of them: "you did that aberation starting from here?".

        Use it for an enum-shaped value: a parse mark's status, a field name being classified.
        @date 2026-09-12 19:00 ]]
        check_name = function(value, what)
            if fields[value] == nil then
                reject(owner, what or name, value)
            end
            return value
        end,

        --[[ The REVERSE of check_keys: every declared name has an entry in `t`.

        The two are one question asked from both ends - "do these sets agree" - and both ends are
        needed where a second table mirrors the declaration. A status with no colour is not a
        quieter mark, it is an invisible one; a colour with no status behind it means the two have
        drifted. Neither direction is implied by the other, and neither is worth writing by hand.

        `what` names the mirroring table in the message, since it is that table which is missing an
        entry, not this declaration.
        @date 2026-09-12 19:15 ]]
        check_covers = function(t, what)
            for key in pairs(fields) do
                if t[key] == nil then
                    error(string.format("%s: %s has no entry for `%s`, which %s declares",
                            owner, what or "the table", tostring(key), name), 3)
                end
            end
            return t
        end,

        --[[ Is this that container? Cheap enough to ask on every call - one table lookup. ]]
        is = function(t)
            return type(t) == "table" and getmetatable(t) == meta
        end,

        --[[ Asserts it, for the top of a function that takes one.

        WHAT THIS CATCHES that the field seal cannot: handing a function the WRONG container. Six of
        these are box states with overlapping field names - `state_text` and `state_definition` both
        have `undo` - so passing one where the other belongs reads every field it shares and goes
        quietly wrong. The seal only sees names, and those names are all declared.

        The message names both types when the value is some other sealed container, because that is
        the case a reader most needs spelled out. Level 3, so the position reported is the caller
        that passed it. ]]
        check = function(t, what)
            if type(t) == "table" and getmetatable(t) == meta then
                return t
            end
            local got = sealed.type_of(t)
            error(string.format("%s: expected %s%s, got %s", owner, type_name, what and (" for `" .. what .. "`") or "",
                    got or (type(t) == "table" and "an unsealed table" or type(t))), 3)
        end,
    }
    DECLARED[#DECLARED + 1] = shape
    return shape
end

--[[ Every container declared anywhere, as {owner, name, fields}.

Populated by require order, so a container appears here only once its file has been loaded - which
is why a caller that wants all of them requires the modules first. Returns the live list; read it.
@date 2026-09-12 06:25 ]]
function sealed.all()
    return DECLARED
end

return sealed
