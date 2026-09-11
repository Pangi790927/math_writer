--[[
panel_help.lua - the F1 screen: what this editor does that no key list can tell you, with every
key name in the prose taken from the live keymap.

The explanations are written by hand, because nothing can derive why an exponent attaches to the
closing bracket, why a selection cannot leave its row or how to type NN literally - and a flat
"key - description" list, which this replaced, has nowhere to put any of it. But no key is ever
written as text. Prose carries PLACEHOLDERS resolved through the keymap at draw time:

    "{formula.new} inserts a formula"   ->   "Ctrl+M inserts a formula"

so rebinding in F2 changes this page with no edit here, and the page cannot go stale about the
keyboard. Those two - hand-written why, generated keys - are what the file is for; everything
below is in service of them.

An action whose binds have all been deleted renders "(unbound)", so the sentence still reads, and
an id the registry does not have renders as "{like.this}" rather than vanishing, because a
silently-dropped placeholder is a typo nobody ever notices. Only the FIRST bind is shown
(keymap.label's own comment): a second alternative should not reflow a paragraph.

The page is an 80-column grid in ImGui's own font. That font is fixed-width, so the column count
is real rather than an approximation, and wrap() can count characters instead of pixels.

@date 2026-09-08 07:43
]]

local vc = require("virt_composer")
local keymap = require("keymap")
local mformula = require("mformula_new")
local mexpru = require("mexpru")
local glyphmap = require("glyphmap")
local char = require("char")
--[[ The help page asks the parser what names it knows rather than keeping its own copy - see the
generated lists below. ]]
local mexpr_ast = require("mexpr_ast")

--[[ content.lua, required on FIRST USE rather than at load.

content.lua requires THIS file (it owns the F1/F2 dispatch), so requiring it back at load time
closes a cycle - which Lua answers with a C stack overflow rather than an error naming the problem.
Deferring costs nothing: nothing here runs before content.draw() has called it, by which point
content is fully loaded. Same idiom as mformula_new.lua's mformula_latex.
@date 2026-09-08 07:43 ]]
local content_mod = nil
local function content_lib()
    if not content_mod then
        content_mod = require("content")
    end
    return content_mod
end

local panel_help = {}

--[[ The page's scale and its grid.

FONT_SCALE 2 - the page is drawn at twice ImGui's normal size (asked for 2026-09-07). Every length
below is in UNSCALED units and multiplied on use, so changing this one number moves the whole
layout together rather than leaving the padding at the old size around bigger text.

COLUMNS is a MAXIMUM, not a promise, and that is a compromise worth knowing about. 80 columns of
doubled ProggyClean is about 1120px, and the window is 1280 wide - which leaves 160px for a sidebar
whose longest entry ("Digraphs and the number sets") needs about 390. The three constraints do not
fit together at this window size, so the page takes as many columns as actually remain, capped at
80. Widen the window and it settles at 80 on its own.
@date 2026-09-08 07:43 ]]
local FONT_SCALE   = 2
local COLUMNS      = 80
local BG_COLOR     = 0xee1a1a1a
local TEXT_COLOR   = 0xffe0e0e0
local DIM_COLOR    = 0xff9a9a9a
local SIDEBAR_W    = 252
-- Key names in the prose are drawn on a chip so they read as keys rather than as words. The
-- resolve() step marks them, since it is the only place that knows which spans came from a
-- binding and which are ordinary text - see KEY_MARK.
local KEY_BG       = 0xff4a4a4a
local KEY_EDGE     = 0xff8a8a8a
local PAD          = 16

--[[ The chapters, and their order is the reading order: what the app IS, then how to put text in
it, then the formula language in the order someone actually meets it, then the things that only
bite once you are fluent. Position is meaning here - CHAPTER_NUMBERS below reads the numbering off
this list, so moving an entry renumbers it and re-files it in one edit.

An entry is {title = ..., body = <a long string>, sub = true?}; `sub` makes it a sub-chapter of
the last top-level entry above it.

A body is prose in a small markup, every piece of which is handled further down this file:

    {action.id}    that action's current first binding, drawn on a chip     resolve()
    @fig <latex>   a real formula, built once per chapter                   build_figures()
    @box           a three-box document drawn by content.draw()             draw_box_kind_example
    @boxkind1..4   one box: text, formula, definition, big definition       draw_box_kind_example
    @letters       the Alt+letter table, generated from glyphmap            draw_letters_reference
    @radial        the new-box radial menu, drawn by content.lua            draw_radial_example

An INDENTED line is preformatted and survives verbatim; a blank line is a paragraph break; every
other line is reflowed to the column width (wrap()). Anything not in braces is literal.
@date 2026-09-08 07:43 ]]
--[[ The lists in "Names the parser knows" are GENERATED from the parser's own tables, never typed
out here. A help page that repeats a table by hand is a copy that goes stale the first time the
table gains a row - and that table gained nine rows in one afternoon.
@date 2026-09-11 12:40 ]]
local NAMED_OPS = table.concat(mexpr_ast.named_operators(), ", ")

local BUILTIN_ONE, BUILTIN_TWO
do
    local one, two = {}, {}
    for _, fn in ipairs(mexpr_ast.builtin_functions()) do
        table.insert(fn.arity == 1 and one or two, fn.name)
    end
    BUILTIN_ONE, BUILTIN_TWO = table.concat(one, ", "), table.concat(two, ", ")
end

local CHAPTERS = {
{title = "Reading this help", body = [[
This page explains what the editor does that is not obvious from watching it.
{help.prev_chapter} and {help.next_chapter} move between chapters, {help.scroll_up} and
{help.scroll_down} scroll the one you are reading and turn the page at its ends, and you
can click any chapter on the left. Each one remembers where you left it. {app.help} or {panel.close} closes the page, and {app.customiser} opens the key
customiser.

A KEY LOOKS LIKE {app.help} - that is a real one, the key this page is open on. Anywhere
a key is named in these pages it is drawn on a raised chip like that, and the name is
read from your own configuration rather than written into the text, so if you rebind
something in {app.customiser} every page here says the new key straight away. An action
you have unbound entirely shows as (unbound) instead.

DRAWINGS ARE THE REAL THING. The pictures below are not illustrations of the editor,
they are the editor's own drawing code called with example values. A box example is
painted by the same function that paints your document, and the menu below by the same
one the menu itself uses. They cannot drift out of date, because there is only one copy.

They are also completely inert. Only the drawing is shared; everything that responds to
a click or a key lives elsewhere and is never reached from this page. Nothing here can
be clicked, typed into, or changed, and nothing you do on this page touches your
document.

THE DOCUMENT IS A STACK OF BOXES, each hanging off the rail on the left. The middle one
here is drawn as the active one, which is what the brighter border means:

@box

The colour is the box's kind. The small x above the top-right corner closes that box,
and the circle on the rail is where a new box would be inserted.

A NEW BOX IS CHOSEN FROM A RADIAL MENU, opened with {box.new} or by clicking the rail.
The formula sector is lit here the way it lights when you hover it:

@radial

Formulas in these pages are typeset by the editor's own formula engine, so what you see
is exactly what typing the same thing would produce:

@fig \frac{a+b}{c}
]]},

{title = "Getting around", body = [[
You are always working in exactly one box, and it is the one with the brighter border:

@box

{box.prev} and {box.next} move between them without the mouse. Every box keeps its own
cursor and selection from when you last left it, so coming back puts you where you
were rather than at the start.

That is also why the FIRST click on an inactive box only gives it focus and does not
move its cursor: the box already knows where you were in it, and a click that was
really about coming back should not throw that away. Click again to place the cursor
where you clicked. Once a box is active, clicking inside it moves the cursor
immediately.

{box.new} opens the new-box menu just after the current box, and clicking the rail
opens it at the point you clicked - chapter 1 shows what the menu looks like. It
answers the keyboard as well as the mouse: {radial.text}, {radial.formula} and
{radial.definition} aim at a kind, {radial.dismiss} aims at the x in the middle,
{radial.commit} makes what is aimed at, and {radial.cancel} closes the menu without
making anything.

{box.move_up} and {box.move_down} move the BOX itself up or down the stack, rather than
moving you between boxes, and the box you are in stays the box you are in - the caret
travels with it. A derived box keeps pointing at whatever it was derived from wherever
either of them ends up, so the order in the document is yours to arrange.

{box.close} closes the box you are in, with no confirmation and no undo. Undo lives
inside a box, so closing one takes its history with it. Moving is undone by moving
back.

The mouse wheel scrolls the stack. Ctrl and the wheel together zoom the document
instead, and formulas you have already typed resize with it rather than only new ones.

{doc.save} saves, and saves again on the way out.
]]},

{title = "The buttons above a box", sub = true, body = [[
Every box carries three small buttons just above its top-right corner, and they are the
same three whatever the box holds:

@box

THE X CLOSES THAT BOX, the same as {box.close} does for the one you are in. There is no
confirmation and no undo - undo lives inside a box, so closing one takes its history
with it.

THE OTHER TWO ARE DEBUGGING VIEWS for the formulas in the box, and they are global
rather than per box: turning one on shows it everywhere. They are worth knowing about
because they explain what the editor thinks the shape of a formula is, which is often
the answer when something moves in a way you did not expect.

THE BOXES VIEW draws the bounding box of every piece of a formula - each glyph, each
slot, each compound. Two things that look adjacent but belong to different levels stop
looking adjacent.

THE GRAPH VIEW draws where the caret can actually go and how the positions connect. If
an arrow key seems to skip somewhere or refuse to leave, this is the view that shows
why: the positions are the model, and the keys only walk between them.

Neither changes the document. They draw on top of it.
]]},

{title = "The three kinds of box", body = [[
Every box is one of three kinds and the colour says which. A kind is chosen when the
box is made, from the menu {box.new} opens, and is never converted afterwards.

A TEXT BOX IS GREY. It holds prose, with formulas set inline anywhere in it:

@boxkind1

This is where most of a document lives, and it is the only kind with a full text editor
behind it - typing, selection, wrapping, undo and the clipboard all work here. Press
{formula.new} and a formula appears at the cursor with you inside it, so a sentence and
the mathematics in it stay one paragraph rather than being split into separate objects.
{formula.exit} puts you back in the prose. The formula is a real one, not a picture:
copying the box yields the LaTeX for everything in it.

A FORMULA BOX IS BLUE. It holds exactly one formula and nothing else:

@boxkind2

Use it when a result deserves to stand alone rather than sit inside a sentence.

The two above are not two separate formulas: the lower one was DERIVED from the upper,
and the curve down the right is that derivation. {formula.derive} makes one - it places
a new box directly below and records where its contents came from.

What it applies is the IDENTITY: the result is exactly the input, unchanged. That is a
real derivation rather than a stand-in for one ("this follows from that, and is the
same") and it is the only one that needs no machinery at all - because the expression
going in and the expression coming out are identical, nothing has to be converted,
rearranged or checked. Every transformation that follows will differ from this one only
in what it does between those two points.

Pasting new content into a box breaks the link, and takes every box derived from it
with it - once the premise has been swapped out, what followed from it no longer
follows from anything, so it is not left behind pretending to.

A DEFINITION BOX IS GREEN. It gives a name a meaning and a type:

@boxkind3

That one reads "x is in the reals". The shape is a NAME PATTERN, then one set per
parameter, then the result type - so a name with no parameters is a plain membership as
here, while "f(x)" makes it a signature and draws an arrow instead. The number of
parameter slots is derived from the free variables in the name, never typed: change the
name and the row reshapes itself.

It scales up without changing shape. This one is from a real document:

@boxkind4

The name is "F" with a decorated subscript and three arguments, so the row carries one
set per parameter - n and m from the subscript, then t, v and a - each written as a
membership, and the last slot is the result type: this F lands in R cubed. Nothing
about that row was typed as a count or a layout; it is all derived from the name.

The row underneath is a GENERATED SHORTHAND restating the slots above it. It is a real
formula and can be selected and copied, but not edited - anything typed into it is
discarded, because it is a view of the cells rather than a cell of its own.

ABOUT SCOPE, honestly: a definition today declares a name and its type, and nothing else
in the editor consults it yet. No other box resolves the name, and typing "x" elsewhere
does not know about a definition of x. Making names actually mean something across boxes
is the next stage of the project rather than something this box already does - so treat
a definition as a statement you have written down, not yet as one the editor enforces.

The three chapters under this one take each kind in turn.
]]},

{title = "The text box", sub = true, body = [[
@boxkind1

The grey box, and where most of a document lives. Everything below applies to it.

TYPING. {text.newline} starts a line, {text.space} inserts a space, {text.backspace}
deletes what is behind the cursor and {text.delete} what is in front.

MOVING. {nav.left} and {nav.right} move a character; {nav.word_left} and
{nav.word_right} skip a whole word. {nav.up} and {nav.down} move by line and keep your
column across the gap. {nav.home} and {nav.end} go to the ends of the line. Hold Shift
with any of those to select instead of move - {nav.select_left} and {nav.select_right},
{nav.select_up} and {nav.select_down}, {nav.select_home} and {nav.select_end},
{nav.select_word_left} and {nav.select_word_right} - and {edit.select_all} takes the
whole box.

{edit.copy}, {edit.cut} and {edit.paste} do the obvious things, and {edit.undo} /
{edit.redo} are per box.

WHAT IS ACTUALLY STORED is a single stream of characters in which a formula occupies one
position, like a very wide letter. That is why the caret walks into a formula rather
than around it, why {nav.left} from just after one enters it at its end, and why
selecting across a formula takes the whole thing and never half of it.

COPYING IS LOSSLESS AND SYMMETRIC. The whole box copies as text with each embed rendered
as $$LaTeX$$, and pasting that back rebuilds real formulas rather than literal dollar
signs. So a box can be moved to another document, or to anything that takes text, and
come back unchanged - and text pasted from elsewhere that happens to contain $$...$$
spans arrives as formulas.

UNDO INCLUDES THE FORMULAS INSIDE IT: a snapshot deep-copies each embed rather than
sharing it, so undoing a change made inside a formula restores that formula and puts you
back inside it, rather than restoring the prose around an embed that has moved on
without it.

WRAPPING is on width, not on word boundaries, so a long word can break mid-way. That is
current behaviour rather than a decision worth defending.
]]},

{title = "The formula box", sub = true, body = [[
The blue box is one formula and the fact that it can be DERIVED - which is the part
worth understanding, since it is what makes a document an argument rather than a list.

A DERIVATION LINK IS BY IDENTITY, not by position. The derived box records the id of
the box it came from, so either can be moved anywhere with {box.move_up} and
{box.move_down} and the link still holds - a parent may even end up below its child, and
the curve simply draws the other way.

THE LINK IS A CLAIM ABOUT CONTENT, so changing the content breaks it. Pasting into a box
drops its own link and deletes every box derived from it, however far down the chain.
That is deliberate and it is not tidiness: what followed from the old content does not
follow from the new content, and leaving those boxes would leave a derivation whose
premise had been swapped out underneath it.

WHAT A TRANSFORMATION WILL BE. Today {formula.derive} applies the identity, and the
result is the input unchanged. The shape of every future one is the same - take the
expression, produce an expression, record where it came from - and they differ only in
what happens in the middle. The identity is the case where that middle is empty, which
is why it needs no conversion machinery at all and works today.

A formula box holds nothing else: no prose, no second formula. If a step needs a
sentence, the sentence belongs in a text box.
]]},

{title = "The definition box", sub = true, body = [[
The green box is the one with real structure, and the one whose rules are easiest to
trip over.

THE ARITY IS DERIVED, NEVER TYPED. The name pattern is parsed, its free variables are
counted, and that count is how many parameter-set slots the row has. Type "f(x)" and one
appears; type "f(x,y)" and a second does. You never enter a number, and the row reshapes
itself as you edit the name.

WHICH MEANS THE NAME CAN BE INVALID while you are typing it, and usually is - halfway
through "f(x" there is nothing to count. The row does NOT rearrange itself under your
cursor when that happens: it keeps the last valid arity and marks the trouble instead,
with a rule under the name slot and per-character marks behind it.

THE NOTATION IS PART OF THE NAME. "a_n" and "a(n)" are different names, not the same one
written differently, because the pattern carries how the thing is written as well as what
it is called - which is what lets a later reference be recognised as the same thing.

THE SHORTHAND ROW IS A VIEW. It restates the slots above as a signature, collapsing runs
of the same domain into powers. It is a real formula and can be selected and copied like
any other, but typing into it is discarded: it has no content of its own to change.
{definition.exit_slot} leaves it and puts the caret back in the name.

MOVING BETWEEN THE SLOTS IS BY MOUSE. Click the name, a parameter's set, or the result
type to work in it - there is no key that steps from one slot to the next today, and the
one out of the shorthand is the Escape above. {edit.undo} and {edit.redo} work here as
they do everywhere, one step per keystroke that actually changed something.

AND IT IS NOT YET CONNECTED TO ANYTHING. Nothing outside the box reads these names today.
]]},

{title = "Greek and symbols", body = [[
Alt and a key gives its Greek letter; Alt+Shift gives the capital, or an operator where
the capital would look identical to its Latin counterpart. This is your CURRENT
configuration, read from the same table the editor types from - change a key in
{app.customiser} and this list changes with it:

@letters

Alt and punctuation reaches the set-theory symbols, paired by where the key sits:
Alt+[ is union and Alt+] intersection, with Shift turning them into or and and.
Alt+, is belongs-to and Alt+. contains, with Shift giving the subset forms.
Alt+1 is negation.

ANYTHING ELSE BY ITS LATEX NAME: type a backslash, the name, then a space, and the run
becomes the symbol. \sum, \infty, \partial, \oplus. The backslash and the letters are
ordinary characters while you type them, so there is no mode to get stuck in - if you
change your mind, just move away and they stay as text.

That is also the vocabulary {app.customiser} accepts, so any name you can type here can
be put on a key of its own.
]]},

{title = "The math box", body = [[
Everything from here on is about writing MATHEMATICS rather than prose - inside a
formula box, or inside a formula embedded in a text box. They are the same editor with
the same keys, so this applies to both:

@boxkind2

{formula.new} makes one inside prose and puts you in it; clicking a formula enters it;
{formula.exit} leaves. Inside, the ordinary letters and digits type as themselves, and
everything else in the chapters below is about the notation that plain characters cannot
reach.

THE THING BEING EDITED IS A TREE, not a line of characters. A fraction has a numerator
and a denominator, a superscript hangs off a base, a bracket knows its partner. That is
why the caret sometimes rests ON something rather than between two things, why
{nav.up} and {nav.down} mean "into the part above / below" here rather than "previous
line", and why deleting a structural piece is a different act from deleting a character.

WHAT FOLLOWS. The pairs of characters that collapse into one sign, brackets, powers and
indices, fractions and stacks, accents, and how to move around inside all of it - one
chapter each. Greek and the symbol keys come just before this chapter, since they are
as useful in a sentence as they are in a formula.
]]},



{title = "Digraphs and the number sets", body = [[
Inside a formula some pairs of characters collapse into one symbol as you type:

@fig a \ge b \le c \ne d

    >=  <=  ->  <-  =>  <=>  <->  !=  ==  ..  _|  ||

A DOUBLED CAPITAL becomes the number set drawn double-struck: NN is the natural
numbers, and ZZ QQ RR CC HH II LL follow the same rule.

@fig \N \subset \Z \subset \Q \subset \R

To type one of those literally instead, put a space between the two characters, then
{nav.left}, {text.backspace}, {nav.right}. The space breaks the pair before it can
combine, and removing it afterwards leaves the two characters side by side.

THAT WORKS BECAUSE THEY FIRE WHILE YOU TYPE AND AT NO OTHER TIME. Nothing rescans a
formula afterwards, so a pair that comes together by pasting, by loading a file, or by
deleting whatever stood between the two characters is left alone - which is also why a
document reopens looking exactly as it was saved.

A typed ~ means similar-to rather than a literal tilde, and ~= is approximately.

An = typed after a relation turns it into its or-equal form: Alt+< then = gives
included-or-equal. That is one rule rather than a separate shortcut per symbol.
]]},

{title = "Formulas inside text", body = [[
{formula.new} inserts a formula where the cursor is and puts you inside it.
{formula.new_frac} does the same but starts with an empty fraction, and
{formula.new_stack} with a stack.

{formula.wrap_sup} and {formula.wrap_sub} take the character immediately before the
cursor and lift it into a superscript or subscript base, making the formula around it
in one step - so you can keep typing rather than inserting a formula first.

@fig x^{2} + y_{i}

Click a formula to enter it. {formula.exit} leaves, as does clicking outside, or
{formula.exit_left} / {formula.exit_right} which leave from whichever side.

Plain {nav.left} and {nav.right} at the formula's own edge do NOT leave it - they stop
there. That is deliberate: walking off the end by accident while editing is worse than
having to ask to leave.
]]},

{title = "Brackets", body = [[
Type ( [ or { and the matching ) ] } pairs with it. A pair grows to fit whatever ends
up between them, however tall that becomes.

{math.bar_bracket} is the | delimiter, and the same shortcut both opens and closes it -
if there is a bar open that can legally close, this closes it; otherwise it opens a new
one. A typed | stays an ordinary character.

An exponent attaches to the CLOSING bracket, never the opening one. This is the only
way to write (a+b) squared: the sup hangs off the ")". Putting one on the "(" means
nothing mathematically, and it used to make the bracket impossible to close, so it is
refused.

@fig (a+b)^{2}
]]},

{title = "Powers, indices, big operators", body = [[
{math.sup} and {math.sub} put a superscript or subscript on whatever the cursor is on.
That thing becomes the BASE, and the new empty slot is where you land.

If the base already has the side you asked for, nothing happens - the slot is filled,
and there is nothing to make.

{math.limit_above} and {math.limit_below} put the slot ABOVE or BELOW instead of beside,
which is what turns a symbol into a big operator: a sum with its index underneath and
its limit on top.

@fig \sum_{i}^{n} x_{i}

Some glyphs are drawn larger than the text around them on purpose. An integral typed at
body size is a thin squiggle otherwise; the display sizes are the proportions real
typesetting uses.
]]},

{title = "Names the parser knows", body = [[
A formula is not only drawn, it is READ. {app.ast} and {app.ast_string} show what the
reader made of the one you are on. The names below are the ones it understands without
being told about them.

WORDS THAT ARE OPERATORS. Make a one-row stack with {formula.new_stack}, then type the
letters into it:

]] .. NAMED_OPS .. [[


Each of these DECLARES the variable written under it and binds it in what follows, the
same way a sum does - the `x` under a `min` is that min's own `x`, not the one outside.

@fig \lim _{x\rightarrow 0}x

A limit is written with an arrow, and the arrow is `-` then `>`.

WORDS THAT ARE FUNCTIONS. These APPLY to an argument instead of declaring a variable, and
they need no definition box. Of one argument:

]] .. BUILTIN_ONE .. [[


and of two:

]] .. BUILTIN_TWO .. [[


How many arguments is part of the name, so a `gcd` of one argument is a different name and
does not read. Defining a name yourself that is already in this list REPLACES it.

@fig \sin (2x+1)

LETTERS. Every Greek glyph counts as a letter, so it can be a variable, a name, or the
thing an operator binds. \sum and \prod are NOT letters - they are operators that happen to
be drawn as Greek capitals, and \Sigma and \Pi are the letters.

INFINITY is a number like any other, on Alt and the 8 key. Being a number rather than a
special case is what lets it stand wherever a number can - most usefully as a bound.

@fig \int _{0}^{\infty }x\,dx

THE INTEGRAL IS A PAIR: its `d` is created together with the sign and belongs to it. That
is what tells the reader where the body stops and which variable is being integrated over,
so there is no way to write one and forget the variable.
]]},

{title = "Fractions and stacks", body = [[
{math.frac} inserts an empty fraction and puts you in the numerator. {nav.up} and
{nav.down} move between numerator and denominator.

@fig \frac{a+b}{c}

{math.stack_grow} starts a stack, and pressing it again adds another cell.
{math.stack_shrink} drops one.

A fraction has no base to attach to, so unlike a superscript it cannot be applied to a
supsub's base - there is nothing there for it to mean.
]]},

{title = "Accents", body = [[
{math.accent_hat} is a hat, {math.accent_tilde} a tilde, {math.accent_bar} a bar, each
on the character the cursor is on. Press the same one again to take it off.

@fig \hat{a} \tilde{b} \bar{c} \vec{d}

Add Shift and the SAME accent goes UNDERNEATH instead: {math.accent_hat_below},
{math.accent_tilde_below}, {math.accent_bar_below}. One rule for the whole family
rather than three unrelated shortcuts to remember.

Dots are the exception, because they count rather than flip sides: {math.dot_add} adds
one above, up to three, and {math.dot_remove} takes one away.

Vector arrows are the other exception: {math.vec} points right and {math.vec_left}
points left. They are different accents, not the same one in two places, which is why
Shift here means direction and not below.
]]},

{title = "Moving inside a formula", body = [[
{nav.left} and {nav.right} walk through everything, including the bases of
superscripts and subscripts. {nav.up} and {nav.down} go into and between the parts of
a fraction or a supsub.

{math.sprint_left} and {math.sprint_right} jump to the next landmark instead of the
next atom - a bracket, an = or a ; - or to the edge of the slot if there is none that
way.

{math.back_up} and {math.back_down} go back the way you came in: from inside a
numerator, back onto the fraction itself rather than further up into it.

{math.select_left} and {math.select_right} select. A selection may never leave the row
it started in. That is a rule, not a limitation to work around: a run of atoms in one
row is a thing that can be cut, copied and re-parsed on its own, and a "selection"
spanning a numerator and part of a denominator is not.
]]},

{title = "Clipboard and interchange", body = [[
{edit.copy} and {edit.cut} on a formula, or a selection inside one, put it on the
clipboard as $$LaTeX$$.

{edit.paste} reads the same form back. A $$...$$ span pasted into text becomes a real
formula; pasted inside a formula, its contents are spliced in at the cursor. Plain
LaTeX without the $$ wrapper is accepted too, so pasting from elsewhere works.

A paste that does not parse changes nothing at all, rather than emptying what was
there. Nor is anything spliced while a bracket is still open, or if the pasted
fragment is not bracket-balanced on its own - both would leave a bracket with no
partner in a formula that was fine a moment ago.
]]},

{title = "Customising the keys", body = [[
{app.customiser} opens the keybind table. Every action in this help page is in it, and
every key name you see here is read from it - change a binding there and this page says
the new key.

TWO WAYS TO SET ONE, because they suit different moments. Click the text and write it -
"Ctrl+Shift+K" - when you know exactly what you want, or when it is a key this keyboard
cannot conveniently press. Click the round record button and press the combination when
you know the shape of the chord in your hands but not its name.

RECORDING NEVER COMMITS BY ITSELF. Every key pressed while it runs is added to the
attempt, letting go changes nothing, and pressing the button again clears it and starts
over; the tick saves and the cross abandons. That is what makes every key bindable,
Escape included - a design that committed on release would have to hold Escape back as
its own way out. A second non-modifier key is refused rather than replacing the first.

AN ACTION CAN HOLD MORE THAN ONE BINDING. This page shows the first; the table shows
them all, with a + to add one and a cross to drop one, and a row says so when another
action can fire on the same keys.

A BINDING IS EXACT: Ctrl+Z means Ctrl and Z with nothing else held. The exception is
the +All suffix, which means "with any modifiers" - {text.newline} is written that way,
so a stray Shift does not swallow your newline.

THE LETTERS SECTION is the other half of the table: what each letter types plain, with
Alt, and with Alt+Shift. Every letter is listed, not only the ones carrying a Greek
letter today, because a key with nothing on it is exactly the key you may want to put
something on. Cells take LaTeX names, checked against the same catalogue the
backslash-name-space entry uses, and an empty plain cell means "the letter itself". The
Greek chapter's table is that map, drawn.

CHANGES ARE SAVED WHEN THE PANEL CLOSES rather than as you type, so a half-written
binding never reaches disk.
]]},

{title = "Saving and the app's own keys", body = [[
YOUR DOCUMENT IS SAVED TO math_writer.save next to the application, by {doc.save} and
again on the way out, and it is read back when the application starts - so you resume on
what was on screen. It is written in the same $$LaTeX$$ form {edit.copy} produces, which
means the file is exactly what selecting everything in every box and copying would have
given you, and it stays readable without this program.

YOUR CONFIGURATION IS NOT IN IT. The key bindings live in keymap.save and the letter map
in glyphmap.save, beside the document and deliberately outside it: a document handed to
somebody else, or checked into a repository, should not drag your keyboard habits along
with it, and either of the two is useful without the other.

THREE KEYS BELONG TO THE APPLICATION rather than to the table {app.customiser} edits.
They cannot be rebound, and that is what they are for: they read the real keyboard
directly, so they keep working when the editor's own side has thrown and every frame is
failing - which is exactly when you need them. They are written here as plain text
rather than on a chip because no binding stands behind them to look up.

CTRL+Q QUITS, saving on the way, by the same path the window's close button takes.

CTRL+SHIFT+D opens a local port that lets a debugging tool drive this instance, and
closes it again. Nothing listens until you ask for it: an editor you are working in
should not sit on an open port.

CTRL+R saves and restarts in place, picking up edited scripts or a rebuilt binary
without leaving the window. A development convenience, marked temporary in the source,
and it works only where re-executing through /proc/self/exe does - so on Linux, not on
Windows.
]]},

{title = "When something is slow", body = [[
{app.profiler} shows a live breakdown of where the frame went. It stays readable while
you work, because a lag spike is over before you could switch to a different view.

{app.profiler_reset} clears its worst-frame record. {app.profiler_record} logs every
frame slower than the threshold to a file, with the overlay hidden, so you can hunt an
intermittent stall without the watching costing anything itself.
]]},
}

--[[ The chapter numbers - "3", "3.1", "3.2", "4" ... - read off the list's ORDER rather than
written into each entry, so a number can never disagree with a position: insert or reorder a
chapter and everything after it renumbers itself. A `sub` entry numbers under the last top-level
one above it.

Computed once at load: CHAPTERS never changes at runtime.
@date 2026-09-08 07:43 ]]
local CHAPTER_NUMBERS = {}
do
    local top, sub = 0, 0
    for i, ch in ipairs(CHAPTERS) do
        if ch.sub then
            sub = sub + 1
            CHAPTER_NUMBERS[i] = top .. "." .. sub
        else
            top, sub = top + 1, 0
            CHAPTER_NUMBERS[i] = tostring(top)
        end
    end
end

--[[ Substitutes {action.id} for that action's current first binding, and marks every substitution
with KEY_MARK so the drawing pass can tell a key from a word.

An id the registry does not have is left in its braces rather than blanked: a placeholder that
silently disappears is a typo that survives forever, while a visible one is caught the first time
the chapter is opened. "@fig" lines are markup for the formula parser, not prose, and pass through
untouched.

  text -> the same text, placeholders replaced, each replacement between \1 bytes.
@date 2026-09-08 07:43 ]]
local function resolve(text)
    --[[ Line by line, so figures can be stepped over: LaTeX is full of braces - x^{2},
    \\mathbb{N}, \\frac{a}{b} - and substituting inside one would at best leave "{2}" alone and at
    worst rewrite a figure into nonsense the day an action happens to be called something short. ]]
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^@fig") then
            out[#out + 1] = line
        else
            out[#out + 1] = (line:gsub("{([%w_.]+)}", function(id)
                local ok, label = pcall(keymap.label, id)
                if not ok or label == nil then
                    return "{" .. id .. "}"
                end
                --[[ Marked HERE because this is the only point that knows a span came from a
                binding: once the line is a string, "Ctrl+W" and the words around it are
                indistinguishable, and hunting for key-shaped substrings afterwards would put a
                chip on prose that merely mentions one. A control byte occurs in neither. ]]
                return "\1" .. label .. "\1"
            end))
        end
    end
    return table.concat(out, "\n")
end

--[[ One line of prose, with any key names on a chip.

Split on the KEY_MARK control byte: odd pieces are ordinary text, even ones are key names. Each
piece is submitted as its own ImGui item on the same line, and the chip is a rectangle drawn behind
the key name on the window draw list - which is why this needs the screen cursor rather than the
window-relative one.
@date 2026-09-08 07:43 ]]
local function draw_marked_line(line)
    if line == "" then
        -- A blank string submits no widget at all, which would swallow the paragraph break.
        vc.ImGui_Text(" ")
        return
    end
    if not line:find("\1") then
        vc.ImGui_Text(line)
        return
    end
    --[[ The line is text, key, text, key, ... split on the marker, so the flag simply alternates -
    including across empty pieces, which is why it flips unconditionally. Each piece is its own
    ImGui item glued to the previous with SameLine(0,0), so a chip lands exactly where the words
    would have been. ]]
    local is_key, first = false, true
    for piece in (line .. "\1"):gmatch("([^\1]*)\1") do
        if piece ~= "" then
            if not first then
                vc.ImGui_SameLine(0, 0)
            end
            first = false
            if is_key then
                local p = vc.ImGui_GetCursorScreenPos()
                local sz = vc.ImGui_CalcTextSize(piece)
                vc.ImGui_AddRectFilled({x = p.x - 3, y = p.y},
                        {x = p.x + sz.x + 3, y = p.y + sz.y}, KEY_BG, 3)
                vc.ImGui_AddRect({x = p.x - 3, y = p.y},
                        {x = p.x + sz.x + 3, y = p.y + sz.y}, KEY_EDGE, 3, 1)
            end
            vc.ImGui_Text(piece)
        end
        is_key = not is_key
    end
end

--[[ Reflow to COLUMNS.

REFLOW, not per-line wrap. The chapters are written with their own line breaks at roughly this
width, but substitution changes the length of every line that holds a placeholder - "{formula.new}"
is 13 characters and "Ctrl+M" is 6 - so wrapping each source line on its own leaves the text ragged,
with a short line after every long one. Consecutive prose lines are joined into a paragraph first
and the paragraph is then broken at COLUMNS, so the page reads evenly whatever the bindings are.

An INDENTED line is never joined or broken: the digraph rows and the sample tables are laid out by
hand and must survive verbatim, and so does an "@" line, which is a figure rather than text. A
blank line ends a paragraph and is kept, since it is the only paragraph break the page has.

  text, columns -> a list of lines, the chapter's leading and trailing blanks removed.
@date 2026-09-08 07:43 ]]
local function wrap(text, columns)
    columns = columns or COLUMNS
    local out = {}
    local para = nil

    local function flush()
        if not para then
            return
        end
        local cur = nil
        -- The KEY_MARK bytes are invisible when drawn, so they must not count towards the column
        -- budget - otherwise a paragraph full of key names wraps several characters early.
        local function visible(t) return #(t:gsub("\1", "")) end
        for word in para:gmatch("%S+") do
            if cur == nil then
                cur = word
            elseif visible(cur) + 1 + visible(word) <= columns then
                cur = cur .. " " .. word
            else
                out[#out + 1] = cur
                cur = word
            end
        end
        if cur then out[#out + 1] = cur end
        para = nil
    end

    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*$") then
            flush()
            out[#out + 1] = ""
        elseif line:match("^%s") or line:match("^@") then
            -- Preformatted: ends the paragraph before it and passes through untouched. "@fig" is
            -- a drawn formula rather than text (see FIGURES in draw()) and must never be reflowed
            -- into the prose around it.
            flush()
            out[#out + 1] = line
        else
            para = para and (para .. " " .. line) or line
        end
    end
    flush()

    -- A chapter body starts and ends with a newline (it is a [[ ]] literal), which would otherwise
    -- render as a blank first and last row.
    while out[1] == "" do table.remove(out, 1) end
    while out[#out] == "" do table.remove(out) end
    return out
end

--[[ The rendered chapter: resolved, wrapped and built into figures once per selection rather than
every frame - the substitution walks the whole chapter and the wrap allocates a table per line,
neither of which belongs in a frame that is otherwise just drawing text.

Keyed on everything that changes the result: which chapter, the keymap revision (a rebinding
rewrites the prose) and the column count (a resize rewraps it).
@date 2026-09-08 07:43 ]]
local cache = {chapter = nil, stamp = nil, lines = nil, figures = nil}

--[[ The logical size figures are built at. Bigger than mexpru.DEFAULT_SIZE because the page around
them is drawn at double the normal font - a formula at body size next to doubled text reads as an
afterthought. char.lua's size table runs biggest-to-smallest, so SUBTRACTING walks it up.
@date 2026-09-08 07:43 ]]
local FIG_SIZE = mexpru.DEFAULT_SIZE - 3

--[[ The example documents the chapters draw, one per @box / @boxkind line, kept by `which`.

Each is a REAL document handed to content.draw() - the same call that draws yours - rather than a
lookalike drawn here. That is the whole point of them: the rail, the per-kind fill, the focus
border, the buttons above each box, the inline formula inside prose, the definition's slots and the
derivation curve all come out of the code that produces the real thing, at whatever it looks like
today, so an example cannot drift from the editor and cannot be missing a part the editor has. The
hand-drawn version this replaced was missing three at once (2026-09-07): no buttons over the boxes,
a definition rendered as an ordinary formula, and no way to show an inline embed at all.

Built once and kept: building one means parsing LaTeX and laying out an editor.

INERT structurally rather than by promise - content.handle_input() is never called on these, and
they are documents of their own, so there is nothing here a click could reach and nothing it could
reach your document through.
@date 2026-09-08 07:43 ]]
local demo_docs = {}

--[[ Builds one example document, filled with something that shows what that kind of box is FOR -
not merely what colour it is.

One box per document rather than one document holding all of them, because each example sits beside
the paragraph that talks about it; 6 is the exception, and is the whole stack for the chapter that
talks about the stack.

  fontset  the fonts to lay the example out with, as for any editor
  which    1  a text box, with a formula set inline in the prose
           2  a formula box
           3  a definition of arity 0 - the membership form
           4  a definition with five parameters, taken from a real document
           5  a formula box and a derivation of it (built, but nothing draws it - see draw())
           6  one box of EACH kind, the middle one active
@date 2026-09-08 07:43 ]]
local function build_demo_doc(fontset, which)
    local content = content_lib()
    local editor_text = require("editor_text")
    local editor_definition = require("editor_definition")
    local kinds = content.box_kinds()

    local doc = content.new()                    -- starts with a single empty text box
    -- 4 is a second DEFINITION example and 5 a pair of FORMULA boxes, so both borrow
    -- another entry's box kind rather than naming a fourth one.
    local kind_index = (which == 4 and 3) or (which == 5 and 2) or which
    -- 6 keeps the text box it was created with and adds the other two beside it.
    if which ~= 1 and which ~= 6 then
        content.insert_box(doc, 1, kinds[kind_index])
        content.remove_box(doc, 2)               -- drop the text box it came with
    end

    if which == 1 then
        editor_text.from_text(doc.boxes[1].editor,
                "Ordinary prose, with a formula set inline: $$a^{2}+b^{2}=c^{2}$$ "
                .. "and the sentence carries on around it.", fontset)
    elseif which == 6 then
        --[[ One of EACH kind in a single document, for the "this is what a stack of boxes looks
        like" picture. The buttons over a box are built in content.draw()'s layout loop rather than
        in draw_box_chrome(), which is why the hand-drawn version had none - see demo_docs. ]]
        local editor_text = require("editor_text")
        editor_text.from_text(doc.boxes[1].editor, "A text box.", fontset)
        content.insert_box(doc, 2, kinds[2])
        doc.boxes[2].fml.latex = "a^{2}+b^{2}=c^{2}"
        content.insert_box(doc, 3, kinds[3])
        local slots = {"x", "\\R"}
        local body = {tostring(#slots), "\n"}
        for _, latex in ipairs(slots) do
            body[#body + 1] = tostring(#latex) .. "\n" .. latex
        end
        editor_definition.from_text(doc.boxes[3].def, table.concat(body), fontset)
        -- The middle one active, so the focus border is visible against the other two.
        doc.active_index = 2
        return doc

    elseif which == 2 or which == 5 then
        doc.boxes[1].fml.latex = "\\frac{a+b}{c} = x^{2}"
        --[[ 5 adds a SECOND box derived from the first, through the same
        content.derive_identity() the editor uses, so the link drawn is a real derivation link -
        while 2 stays a single box, for the places that only want "this is a formula box".

        Written for the derivation chapter, to show the curve it talks about rather than merely
        claim it exists, but no chapter asks for it and draw() maps no "@boxkind5" - so this branch
        is unreachable today. ]]
        if which == 5 then
            content.derive_identity(doc, 1)
        end
    elseif which == 4 then
        --[[ A REAL definition, taken from an actual document rather than invented for the page:
        a function with decorated subscripts, five parameters each with its own set, landing in a
        product. It exists to show that the shape scales - the simple membership above is the same
        machinery with nothing in it. ]]
        local slots = {
            "F_{1^{23.22},'abcd^{2}',n,m}(t,v,a)",
            "n\\in \\N", "m\\in \\N", "t\\in \\R", "v\\in \\R",
            "a\\in \\{0,3,4\\}",
            "\\R ^{3}",
        }
        local body = {tostring(#slots), "\n"}
        for _, latex in ipairs(slots) do
            body[#body + 1] = tostring(#latex) .. "\n" .. latex
        end
        editor_definition.from_text(doc.boxes[1].def, table.concat(body), fontset)
    else
        --[[ A name with NO free variables has arity 0, and the box then draws the membership form
        - "x is in the reals" - rather than a function signature. "\\R" is the double-struck set,
        the same glyph typing RR produces; a plain "R" would draw an ordinary italic letter and
        say something different.

        editor_definition.to_text()'s exact format, and worth reading before writing another one:
        the slot count and a newline, then each slot as "<len>\n<latex>" with NO separator between
        slots. Newlines between them - which looks more natural - load only the FIRST slot, because
        from_text() reads the separator as the next length and stops, and the definition comes out
        with empty sets: a bug that reads as the editor's and is the string's. ]]
        local slots = {"x", "\\R"}
        local body = {tostring(#slots), "\n"}
        for _, latex in ipairs(slots) do
            body[#body + 1] = tostring(#latex) .. "\n" .. latex
        end
        editor_definition.from_text(doc.boxes[1].def, table.concat(body), fontset)
    end

    -- Nothing active: these are examples, and a focus border here would suggest one of them is
    -- where you are. Chapter 1's stack is where the active/inactive difference is shown.
    doc.active_index = nil
    return doc
end

--[[ Draws one example document at the cursor, and reserves the room it took.

Built on first use and kept afterwards. A build that throws is remembered as `false` and the page
prints a placeholder in its place: a help page must never be the thing that takes the app down, and
a missing example is a far smaller problem than a chapter that cannot open.

  fontset, which  as build_demo_doc
  body_w          the text column's width, off which the box's own is worked out below
@date 2026-09-08 07:43 ]]
local function draw_box_kind_example(fontset, body_w, which)
    local content = content_lib()
    if demo_docs[which] == nil then
        local ok, doc = pcall(build_demo_doc, fontset, which)
        demo_docs[which] = ok and doc or false
    end
    local doc = demo_docs[which]
    if not doc then
        vc.ImGui_Text("   [example unavailable]")
        return
    end
    local screen = vc.ImGui_GetCursorScreenPos()
    --[[ The column's width, less what content.draw() spends around a box: BOX_LEFT (80) for the
    rail and the gap to it, the matching right margin, the derivation-curve gutter, and the child's
    own scrollbar. Subtracting too little put the box hard against the scrollbar - reported
    2026-09-07 as "almost if not outside of bounds". ]]
    local avail = math.max(180, (body_w or 420) - 210)
    content.draw(doc, fontset, {x = screen.x, y = screen.y + 14}, {max_width = avail})
    --[[ Reserve the MEASURED height once there is one, and only guess on the very first frame.

    The floor used to apply always, so a small example still reserved 200px and left a dead gap
    under it before the text resumed. It exists for the first frame alone: content.draw() has not
    measured anything yet, and guessing too small there clips whatever the guess did not cover
    against the child's content rect, with the following text already sitting on top of it. ]]
    local reserved = doc.last_total_height and (doc.last_total_height + 26) or 226
    vc.ImGui_Dummy({x = 10, y = reserved})
end

--[[ The size the reference glyphs are built at - SMALLER than the body text they sit beside. Note
the direction: char.lua's size table runs biggest-to-smallest, so a LARGER index is a SMALLER
glyph. "- 2" made these bigger than their own line and each one spilled into the row below, which
read as the glyphs being drawn against the wrong key.
@date 2026-09-08 07:43 ]]
local REF_SIZE = mexpru.DEFAULT_SIZE

--[[ The built glyphs, kept by name. Never invalidated, and needing no invalidation: the key is the
glyph's own name ("\\alpha") rather than the key that types it, so remapping the keyboard cannot
make an entry of it wrong. ]]
local ref_cache = nil

--[[ One glyph of the reference, built as a one-symbol formula and kept.

Built through mformula rather than placed by hand with fontset:char_draw(): char_draw takes a
BASELINE where AddText takes a top edge, and the size index runs backwards, so two attempts at
hand-placing put every glyph a row out, each wrong in a different direction. mformula.measure()
answers where the ink actually is and mformula.draw() is the path the @fig figures already use, so
the alignment problem stays solved in the one place that solved it.

A name that does not parse is remembered as `false` and drawn as nothing.

  fontset, desc -> the built formula, or nil for a nil or unparseable desc.
@date 2026-09-08 07:43 ]]
local function ref_glyph(fontset, desc)
    if not desc then
        return nil
    end
    ref_cache = ref_cache or {}
    if ref_cache[desc] == nil then
        local ok, c = pcall(mformula.from_latex, fontset, REF_SIZE, desc)
        ref_cache[desc] = (ok and c) or false
    end
    return ref_cache[desc] or nil
end

--[[ THE ALT+LETTER TABLE, generated from the live glyph map rather than written out.

Listing "Alt+A is alpha, Alt+B beta" in prose was wrong twice over: it duplicated a table that
already exists, and once the letters became customisable it was not at risk of going stale, it was
stale the moment anybody remapped anything - the page would recite the factory layout while the
keys did something else. So it reads glyphmap, the same map the editor types from, and draws each
symbol through the same formula path the editor draws it with: remap a key and this page says so,
and what it shows is the actual glyph rather than a description of one.

Keys with nothing mapped are skipped - a reference listing 26 letters of which several do nothing
is mostly noise - and each row is as tall as its own glyphs, which is what keeps the display
operators from colliding with the rows around them (see glyph_height).

  fontset  the fonts to draw the glyphs with
  body_w   unused: the table is laid out at fixed offsets, for the reason given below
@date 2026-09-08 07:43 ]]
local function draw_letters_reference(fontset, body_w)
    local rows = {}
    glyphmap.each(function(key_name, slots)
        if slots.alt or slots.alt_shift then
            rows[#rows + 1] = {key = glyphmap.key_label(key_name),
                    alt = slots.alt, alt_shift = slots.alt_shift}
        end
    end)

    --[[ ONE column at fixed offsets: two collided at the doubled page font, where a row needs
    roughly 500px against a text column of about 700. The page scrolls; a reference that overlaps
    itself is not a reference. Offsets are absolute because two renderers share each line - ImGui
    text for the labels, mformula for the glyphs - and they share no cursor. ]]
    local line = vc.ImGui_GetFontSize() + 14
    local screen = vc.ImGui_GetCursorScreenPos()
    local X_KEY, X_G1, X_N1, X_SH, X_G2, X_N2 = 10, 120, 160, 330, 420, 460

    --[[ Returns the WIDTH it drew, so the name can be placed after the glyph rather than at a
    fixed offset. A display operator is several times wider than a Greek letter, and a fixed column
    put "\\prod" hard against the side of the sign it was labelling. ]]
    local function put(desc, x, y)
        local c = ref_glyph(fontset, desc)
        if not c then
            return nil
        end
        -- measure gives `top` as a NEGATIVE height above the baseline, so subtracting it from the
        -- row's top edge is what puts the ink inside the row instead of above or below it.
        local m = mformula.measure(c, fontset, REF_SIZE, nil)
        mformula.draw(c, fontset, {x = x, y = y - m.top + 2}, REF_SIZE, false, false, nil)
        return m.width
    end

    --[[ How tall one row has to be, asked of its own glyphs rather than fixed. The DISPLAY
    operators - \\int, \\sum, \\prod, \\bigcup - carry a size boost in char.lua
    (size_delta_by_desc, -7), because a display integral at body size is a thin squiggle rather
    than the sign it means; in a fixed text-height row they overflow and collide with the keys
    above and below (2026-09-07: "int prod sum need more space"). An ordinary Greek letter measures
    shorter than the line, so the rest of the table is unaffected. ]]
    local function glyph_height(desc)
        local c = ref_glyph(fontset, desc)
        if not c then
            return 0
        end
        local m = mformula.measure(c, fontset, REF_SIZE, nil)
        return m.bottom - m.top
    end

    local y = screen.y
    for _, row in ipairs(rows) do
        local h = math.max(line, glyph_height(row.alt) + 8, glyph_height(row.alt_shift) + 8)
        -- The label sits on the FIRST text line of the row rather than centred in it: with a tall
        -- operator beside it, a centred label drifts away from the key it names.
        vc.ImGui_AddText({x = screen.x + X_KEY, y = y}, TEXT_COLOR, "Alt+" .. row.key)
        local w1 = put(row.alt, screen.x + X_G1, y)
        if w1 then
            vc.ImGui_AddText({x = math.max(screen.x + X_N1, screen.x + X_G1 + w1 + 12), y = y},
                    DIM_COLOR, row.alt)
        end
        if row.alt_shift then
            vc.ImGui_AddText({x = screen.x + X_SH, y = y}, DIM_COLOR, "+Shift")
            local w2 = put(row.alt_shift, screen.x + X_G2, y)
            if w2 then
                vc.ImGui_AddText({x = math.max(screen.x + X_N2, screen.x + X_G2 + w2 + 12), y = y},
                        DIM_COLOR, row.alt_shift)
            end
        end
        y = y + h
    end
    vc.ImGui_Dummy({x = 10, y = (y - screen.y) + 12})
end

--[[ The radial new-box menu, drawn by content.lua's own draw_radial_at() through
content.draw_demo_radial() - same wedges, same colours, same geometry as the live menu, with the
formula sector lit so the hover state is visible.
@date 2026-09-08 07:43 ]]
local function draw_radial_example()
    local content = content_lib()
    local r = content.radial_extent()
    local screen = vc.ImGui_GetCursorScreenPos()
    local cx = screen.x + 40 + r
    local cy = screen.y + r + 6
    content.draw_demo_radial(cx, cy, content.box_kinds()[2])
    vc.ImGui_Dummy({x = r * 2 + 80, y = r * 2 + 16})
end

--[[ Builds every "@fig <latex>" line of a chapter into a real formula, once, when the chapter is
selected - not per frame. from_latex() parses and lays out a whole tree, which is not something to
repeat sixty times a second for text that never changes.

A figure that fails to parse is stored as `false` and drawn as a placeholder rather than raised: a
help page must never be the thing that takes the app down, and a missing diagram is a far smaller
problem than a chapter that cannot open. The test alongside this file catches the typo instead.

  lines, fontset -> line index -> formula, for the "@fig" lines only.
@date 2026-09-08 07:43 ]]
local function build_figures(lines, fontset)
    local figs = {}
    for i, line in ipairs(lines) do
        local latex = line:match("^@fig%s+(.+)$")
        if latex then
            local ok, container = pcall(mformula.from_latex, fontset, FIG_SIZE, latex)
            figs[i] = (ok and container) or false
        end
    end
    return figs
end

--[[ The panel's state. It is created with the content state and lives there, not here, which is
what makes a reading position survive closing and reopening the panel.

  chapter         index into CHAPTERS - the chapter on screen
  scroll_of       chapter index -> the offset that chapter was last read at
  pending_scroll  a scroll to apply on the coming frames: an offset, "top" or "bottom"
  pending_frames  how many frames that request has left to run; see draw()
@date 2026-09-08 07:43 ]]
function panel_help.new_state()
    return {chapter = 1, pending_scroll = nil, scroll_of = {}}
end

--[[ Draws the whole screen - chapter list on the left, the chapter itself on the right.

Called from content.draw() while state.show_help is set. content's own handle_input has already
returned early by then, so this owns the frame: it may submit real widgets, and it reads the
navigation keys itself rather than being handed them.

  hstate   the state from new_state(); read and written
  stamp    content's keymap revision. It joins the page's cache key, so a rebinding rewrites the
           prose on the next frame rather than at the next chapter change
  fontset  the fonts figures and examples are built with; without one they are skipped
@date 2026-09-08 07:43 ]]
function panel_help.draw(hstate, stamp, fontset)
    local size = vc.ImGui_GetDisplaySize()
    vc.ImGui_AddRectFilled({x = 0, y = 0}, {x = size.x, y = size.y}, BG_COLOR, 0)

    --[[ Everything from here to PopFont is drawn at the doubled size. PushFont(nil, size) keeps the
    font and changes only its size, so this is independent of which font ImGui is using. ]]
    local base = vc.ImGui_GetFontSize and vc.ImGui_GetFontSize() or 13
    vc.ImGui_PushFont(base * FONT_SCALE)

    local PAD = PAD * FONT_SCALE
    local SIDEBAR_W = SIDEBAR_W * FONT_SCALE
    -- One character's width AT THE PUSHED SIZE - measured rather than assumed, since it is what
    -- decides how many columns actually fit.
    local char_w = vc.ImGui_CalcTextSize("0").x
    local line_h = base * FONT_SCALE + 2
    local body_x = PAD + SIDEBAR_W + PAD
    local columns = COLUMNS
    if char_w > 0 then
        -- Two characters held back for the body child's vertical scrollbar, which takes width
        -- the cursor arithmetic above cannot see - without it the last word of a full line is
        -- clipped by the scrollbar rather than wrapping.
        columns = math.max(28, math.min(COLUMNS,
                math.floor((size.x - body_x - PAD) / char_w) - 2))
    end

    vc.ImGui_SetCursorPos({x = PAD, y = PAD})
    vc.ImGui_Text("Math Writer - help    (" .. keymap.label("app.help") .. " or "
            .. keymap.label("panel.close") .. " closes,  "
            .. keymap.label("app.customiser") .. " customises the keys)")

    -- Chapter list, left. A child region so a long list scrolls on its own rather than pushing
    -- the page off the bottom.
    vc.ImGui_SetCursorPos({x = PAD, y = PAD + line_h * 2})
    if vc.ImGui_BeginChild("help_chapters",
            {x = SIDEBAR_W, y = size.y - PAD * 2 - line_h * 2}, 0, 0) then
        for i, ch in ipairs(CHAPTERS) do
            -- PushID per row: every Selectable would otherwise be identified by its label alone,
            -- and two chapters that ever share a title would become the same widget.
            vc.ImGui_PushID("chapter" .. i)
            --[[ The number is added HERE rather than stored in the chapter's own title: it is a
            position in the list, not part of the name, so it stays correct when chapters are
            reordered or one is inserted, and the title itself remains clean for the help's own
            test and for anything that quotes it. ]]
            -- Sub-chapters are indented under their parent; the number already says which is
            -- which, and the indent makes the shape readable at a glance.
            local label = (ch.sub and "   " or "") .. CHAPTER_NUMBERS[i] .. ". " .. ch.title
            if vc.ImGui_Selectable(label, i == hstate.chapter, 0, {x = 0, y = 0})
                    and i ~= hstate.chapter then
                --[[ Picked from the list: restore where this chapter was left, or start at the top
                if it has never been opened. The scroll of the chapter being LEFT was recorded by
                the body block above on this same frame, so it is already safe to switch away. ]]
                hstate.chapter = i
                hstate.pending_scroll = (hstate.scroll_of and hstate.scroll_of[i]) or "top"
                hstate.pending_frames = 2
            end
            vc.ImGui_PopID()
        end
    end
    vc.ImGui_EndChild()

    -- Page, right.
    local ch = CHAPTERS[hstate.chapter] or CHAPTERS[1]
    -- `columns` joins the cache key: a resize changes the wrap, and a page cached at the old width
    -- would keep its old line breaks until the chapter was switched.
    if cache.chapter ~= hstate.chapter or cache.stamp ~= stamp or cache.columns ~= columns then
        cache.chapter, cache.stamp, cache.columns = hstate.chapter, stamp, columns
        cache.lines = wrap(resolve(ch.body), columns)
        cache.figures = fontset and build_figures(cache.lines, fontset) or {}
    end

    local x = body_x
    vc.ImGui_SetCursorPos({x = x, y = PAD + line_h * 2})
    vc.ImGui_Text(CHAPTER_NUMBERS[hstate.chapter] .. ". " .. ch.title)

    --[[ SetCursorPos AGAIN, immediately before BeginChild. After a Text() ImGui puts the cursor
    back at the window's own content x, not at the x that Text was drawn at - so without this the
    body child is placed at the left edge and covers the chapter list. ]]
    vc.ImGui_SetCursorPos({x = x, y = PAD + line_h * 3})
    local body_w = size.x - x - PAD
    if vc.ImGui_BeginChild("help_body",
            {x = body_w, y = size.y - PAD * 2 - line_h * 3}, 0, 0) then
        --[[ ARROWS SCROLL FIRST, and only turn the page once this one has nothing left to give in
        that direction (asked for 2026-09-07): a chapter running past the window was otherwise
        unreadable by keyboard alone, since Down left it from the top and everything below the fold
        needed the wheel.

        Handled INSIDE the child, because that is the window whose scroll these calls report -
        outside it they answer for the page behind. A chapter change parks a request instead of
        scrolling now: the new content has not been laid out, so its extent is not known yet.

        Clamped, not wrapped: running off the end of a list you can see all of and reappearing at
        the other end only loses your place. ]]
        local step = line_h * 3
        local y, maxy = vc.ImGui_GetScrollY(), vc.ImGui_GetScrollMaxY()

        --[[ EACH CHAPTER REMEMBERS WHERE YOU LEFT IT (asked for 2026-09-07): recorded every frame
        the page is simply being read, and handed back on return - including after the panel is
        closed and reopened, since this state lives in the content state rather than in this file.
        A remembered position beats the directional default below, because landing where you were
        reading is what returning means; only a chapter never opened falls back to top or bottom
        depending on which way you arrived at it. ]]
        hstate.scroll_of = hstate.scroll_of or {}

        local function go_to_chapter(n, fallback)
            -- Save this chapter's place before leaving it, or returning would restore whatever it
            -- held the previous time rather than where you actually are now.
            hstate.scroll_of[hstate.chapter] = y
            hstate.chapter = n
            hstate.pending_scroll = hstate.scroll_of[n] or fallback
            hstate.pending_frames = 2
        end

        if hstate.pending_scroll ~= nil then
            --[[ Applied over TWO frames, not one, and the difference is visible.

            ImGui reports a window's scroll extent from the size measured on the PREVIOUS frame,
            and the chapter changes inside this child - so on the following frame GetScrollMaxY()
            still describes the OUTGOING chapter, and applying once clamps against the wrong
            maximum. Leaving a long chapter for a short one and coming back landed part-way through
            it, and "bottom" landed at the short chapter's bottom (2026-09-07: 3 -> 3.1 and back
            did not return to the end of 3). The second application meets the new chapter's own
            extent; the first is not wasted, it puts the page approximately right so nothing
            visibly jumps. ]]
            local want
            if hstate.pending_scroll == "top" then
                want = 0
            elseif hstate.pending_scroll == "bottom" then
                want = maxy
            else
                -- A chapter may have been re-wrapped narrower since you left it, so a remembered
                -- offset can genuinely be past its end - clamped against the SETTLED extent.
                want = math.max(0, math.min(hstate.pending_scroll, maxy))
            end
            vc.ImGui_SetScrollY(want)
            hstate.pending_frames = (hstate.pending_frames or 2) - 1
            if hstate.pending_frames <= 0 then
                hstate.pending_scroll = nil
                hstate.pending_frames = nil
            end
        else
            -- Only recorded while actually reading - never on the frame a restore is being
            -- applied, when `y` is still the outgoing page's.
            hstate.scroll_of[hstate.chapter] = y

            --[[ LEFT/RIGHT jump straight to the neighbouring chapter, whatever the scroll. A
            long chapter was otherwise only reachable end-to-end by holding Down through all of
            it, and moving between chapters is a different intention from reading one. ]]
            if keymap.pressed("help.next_chapter") then
                if hstate.chapter < #CHAPTERS then
                    go_to_chapter(hstate.chapter + 1, "top")
                end
            elseif keymap.pressed("help.prev_chapter") then
                if hstate.chapter > 1 then
                    --[[ "top", not "bottom": arriving by a deliberate jump means you want the
                    chapter, so it starts at its beginning. Up/Down below arrive by running off an
                    edge, which is the case where landing at the near end is what continues the
                    reading. Either way a remembered position still wins. ]]
                    go_to_chapter(hstate.chapter - 1, "top")
                end

            -- UP/DOWN scroll, and only turn the page once this one has no more to give.
            elseif keymap.pressed("help.scroll_down") then
                if y < maxy - 1 then
                    vc.ImGui_SetScrollY(math.min(maxy, y + step))
                elseif hstate.chapter < #CHAPTERS then
                    go_to_chapter(hstate.chapter + 1, "top")
                end
            elseif keymap.pressed("help.scroll_up") then
                if y > 1 then
                    vc.ImGui_SetScrollY(math.max(0, y - step))
                elseif hstate.chapter > 1 then
                    --[[ Arriving at the previous chapter from BELOW lands at its end - the part
                    you were next to - rather than skipping everything between. Only when it has
                    no remembered position of its own, which takes precedence. ]]
                    go_to_chapter(hstate.chapter - 1, "bottom")
                end
            end
        end

        for i, line in ipairs(cache.lines) do
            local fig = cache.figures and cache.figures[i]
            if fig then
                --[[ A real formula, drawn through the same mformula path the editor uses, so what
                the help shows is what the editor would actually produce - not a picture of it.

                ImGui knows nothing about it, so the layout cursor has to be walked past it by
                hand: measure gives top (negative, above the baseline) and bottom, the draw takes a
                BASELINE rather than a top edge, and the window-relative cursor is then advanced by
                the full height so the next line does not overlap. ]]
                local m = mformula.measure(fig, fontset, FIG_SIZE, nil)
                local screen = vc.ImGui_GetCursorScreenPos()
                local height = m.bottom - m.top
                mformula.draw(fig, fontset, {x = screen.x + 24, y = screen.y - m.top + 4},
                        FIG_SIZE, false, false, nil)
                --[[ Dummy, NOT SetCursorPos. The formula goes straight onto the draw list, so
                ImGui has no idea any space was used; something must claim it or the next line
                overlaps. Moving the cursor by hand instead asserts outright the moment the figure
                reaches past the content edge ("Code uses SetCursorPos() to extend window
                boundaries... submit an item e.g. Dummy() afterwards") - which is exactly what
                happened, and it killed the app rather than misdrawing. ]]
                vc.ImGui_Dummy({x = m.width + 24, y = height + 12})
            elseif line:match("^@fig") then
                -- Parsed as a figure but failed to build; say so rather than showing a blank gap.
                vc.ImGui_Text("   [figure unavailable]")
            elseif line == "@box" then
                draw_box_kind_example(fontset, body_w, 6)
            elseif line == "@boxkind1" then
                draw_box_kind_example(fontset, body_w, 1)
            elseif line == "@boxkind2" then
                draw_box_kind_example(fontset, body_w, 2)
            elseif line == "@boxkind3" then
                draw_box_kind_example(fontset, body_w, 3)
            elseif line == "@boxkind4" then
                draw_box_kind_example(fontset, body_w, 4)
            elseif line == "@letters" then
                draw_letters_reference(fontset, body_w)
            elseif line == "@radial" then
                draw_radial_example()
            else
                draw_marked_line(line)
            end
        end
    end
    vc.ImGui_EndChild()
    vc.ImGui_PopFont()
end

-- Exposed for the tests: every {placeholder} in every chapter must name a real action.
-- @date 2026-09-08 07:43
function panel_help.chapters()
    return CHAPTERS
end

return panel_help
