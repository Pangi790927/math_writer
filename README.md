# Math Writer - Interactive Math Expression Editor

## Project Overview

**Math Writer** is an interactive mathematical expression editor that allows users to create, manipulate, and visualize mathematical formulas. The project combines C++ for the UI and rendering backend with Lua for mathematical expression AST (Abstract Syntax Tree) manipulation and drawing logic.

### Core Concept
The application aims to provide a WYSIWYG (What You See Is What You Get) math editor where users can:
- Create complex mathematical expressions
- Navigate and edit expressions using gestures/keyboard
- Support undo/redo operations (ctrl+z, ctrl+shift+z)

## Project Structure

```
math_writer/
├── README.md                   # This file - project documentation
├── TODO.md                     # Current tasks and roadmap
├── makefile                    # Main makefile (platform-agnostic)
├── linux.makefile              # Linux-specific build configuration
├── windows.makefile            # Windows-specific build configuration
├── main.cpp                    # Entry point - ImGui initialization and main loop
├── main.lua                    # Main Lua script - test drawing and entry points
│
├── # Core C++ Headers (Project-Specific)
├── char_draw_composer.h        # Character and font drawing composer
└── math_expr_composer.h        # Math expression drawing composer
│
├── # Lua Scripts
├── ast.lua                     # AST (Abstract Syntax Tree) node representation and operations
├── char.lua                    # Character drawing functions and font management
├── mexpr.lua                   # Math expression calling
└── transforms.lua              # AST transformation utilities
│
├── # Configuration
├── math_writer.yaml            # Main application configuration
├── imgui.ini                   # ImGui configuration (generated)
│
├── # Dependencies (Referenced)
├── GLFW/                       # GLFW header files
├── glfw3.dll                   # GLFW library (Windows)
├── glfw3.lib                   # GLFW import library (Windows)
│
├── # External Resources
├── fonts/                      # Font files for math symbols
│   └── amsfonts-ttf/            # AMS Fonts (LaTeX-style math fonts)
│       ├── README.md
│       └── LICENSE.md
├── docs/                       # Documentation and reference materials
│   ├── texbook.pdf             # TeX reference manual
│   └── tb87jackowski.pdf       # Typographic reference
│
└── old/                        # Legacy code and previous attempts
    └── oldold/                  # Very old legacy code
```

### External Dependencies (in ../)

```
../
├── imgui/                      # Dear ImGui library
├── implot/                     # ImPlot library (plotting for ImGui)
└── utils/                      # Utility libraries
    ├── virt_composer.h         # Core virtual composer framework
    ├── virt_composer.cpp       # Implementation
    ├── virt_composer_end.h     # End of virt_composer namespace
    ├── virt_object.h           # Virtual object base classes
    └── ...
```

## Architecture

### Technology Stack
- **Language**: C++20 (with C++2a features)
- **UI Framework**: Dear ImGui (with GLFW + OpenGL3 backend)
- **Scripting**: Lua 5.x (embedded in C++ via virt_composer)
- **Configuration**: YAML (using fkyaml library)
- **Fonts**: TrueType fonts (TTF) via ImGui's font system

### Core Components

#### 1. virt_composer (from ../utils/)
The virtual composer framework provides:
- Lua-C++ interop system
- Virtual object type system with registration
- YAML configuration parsing
- State management (`virt_state_t`)
- Lua script loading and execution

#### 2. char_draw_composer
Responsible for:
- Font loading and management (`fontset_t`)
- Character drawing with bounding boxes
- Font size and style management
- Character metrics and positioning

Key types:
- `char_t`: Represents a character with size and Unicode code point
- `fontset_t`: Manages multiple fonts and sizes
- `char_bb_t`: Bounding box for characters
- `char_sz_t`: Size metrics for characters

#### 3. math_expr_composer
Responsible for:
- Math expression layout and rendering
- Mathematical symbol drawing
- Expression composition (fractions, superscripts, subscripts, etc.)
- Integration with the AST from Lua

Provides Lua functions:
- `mexpr_symbol`: Create a symbol expression
- `mexpr_supsub`: Create superscript/subscript expressions
- `mexpr_binexpr`: Create binary operator expressions
- `mexpr_frac`: Create fraction expressions
- `mexpr_bigop`: Create big operators (sum, integral, etc.)
- `mexpr_bracket`: Create bracketed expressions
- `mexpr_draw`: Draw math expressions

#### 4. Lua Scripts

**ast.lua**:
- Defines AST node types (EQ, ADD, MUL, NUM, VAR, VREF, etc.)
- Namespace management for AST nodes
- AST creation, copying, and traversal functions
- LaTeX export functionality (`to_latex`)
- String representation (`to_string`)

**char.lua**:
- Font set loading and management
- Character drawing functions exposed to Lua
- Character positioning and layout utilities
- Special character codes for math symbols

**mexpr.lua**:
- Bridge between Lua AST and C++ math_expr_composer
- Math expression tree creation from AST
- Layout calculations for math expressions
- Drawing coordination

**transforms.lua**:
- AST transformation utilities
- Node finding and traversal
- Tree manipulation functions

### Data Flow

```
User Input (Keyboard/Mouse)
    ↓
ImGui Event Handling (main.cpp)
    ↓
Lua Callback (test_draw in main.lua)
    ↓
AST Creation/Modification (ast.lua)
    ↓
Math Expression Conversion (mexpr.lua)
    ↓
Math Expression Drawing (math_expr_composer)
    ↓
Character Drawing (char_draw_composer)
    ↓
ImGui Rendering (via virt_composer)
    ↓
Screen Display
```

## AST (Abstract Syntax Tree) Structure

The AST represents mathematical expressions using a tuple-based structure:

### Node Types (from ast.lua)

| Type | Constant | Description | Lua Tuple |
|------|----------|-------------|-----------|
| Invalid | INVALID | Invalid/unset node | - |
| Equality | EQ | Equality (a = b) | `(=, a1, a2)` |
| Less Than | INEQ_LESS | Inequality (a < b) | `(<, a1, a2)` |
| Less or Equal | INEQ_LEQ | Inequality (a ≤ b) | `(<=, a1, a2)` |
| Not Equal | INEQ_NEQ | Inequality (a ≠ b) | `(!=, a1, a2)` |
| Greater Than | INEQ_GREATER | Inequality (a > b) | `(>, a1, a2)` |
| Greater or Equal | INEQ_GEQ | Inequality (a ≥ b) | `(>=, a1, a2)` |
| Addition | ADD | Sum of elements | `(+, a1, a2, ...)` |
| Multiplication | MUL | Product of elements | `(*, a1, a2, ...)` |
| Division | DIV | Division | `(/, a1, a2)` |
| Exponentiation | EXP | Exponentiation | `(^, a1, a2)` |
| Number | NUM | Rational/natural number | `(N, m, n, sign)` |
| Function Call | CALL | Function application | `(@, f, a1, a2, ...)` |
| Variable | VAR | Named variable | `(#, name)` |
| Vector | VEC | Vector | `(V, a1, a2, ...)` |
| Matrix | MAT | Matrix | `(M, m, n, a1, ..., a[m+n])` |
| Parenthesis | CELL | Parentheses | `(_, a1)` |
| Variable Reference | VREF | Reference to variable | `(&, id)` |

### AST Node Structure
Each AST node is a Lua table with:
- `type`: The node type (from ast.* constants)
- `id`: Unique identifier within a namespace
- `[1]`, `[2]`, ...: Child nodes (varies by type)
- Additional type-specific fields

### Example AST Creation (from main.lua)
```lua
local ns = ast.new_ns()
local a = ast.new_var(ns, "a")
local node = ast.new_eq(ns,
    ast.new_vref(ns, a),
    ast.new_add(ns,
        ast.new_num(ns, 10, 1, 1),
        ast.new_num(ns, -10, 1, 1)
    )
)
```

This creates: `a = 10 + -10`

## Math Expression Drawing

The drawing system uses a hierarchical approach:

### Expression Types (from math_expr_composer)

1. **mexpr_symbol**: Single character/symbol
2. **mexpr_supsub**: Superscript and/or subscript
3. **mexpr_binexpr**: Binary operator (e.g., a + b)
4. **mexpr_unarexpr**: Unary operator (e.g., -a)
5. **mexpr_frac**: Fraction (numerator/denominator)
6. **mexpr_bigop**: Big operators (sum, integral, product)
7. **mexpr_bracket**: Bracketed expressions (parentheses, square, curly)
8. **mexpr_merge_h/v**: Horizontal/vertical merging
9. **mexpr_empty**: Empty space/placeholder

### Drawing Process
1. Lua creates AST nodes
2. `mexpr.to_mexpr()` converts AST to math expression tree
3. `vc.mexpr_draw()` renders the expression tree
4. Character drawing handles individual symbols

### Important Observations (from comments in code)

- **Big operators** (sum, integral) need to be around 4-5 font sizes bigger than surrounding text
- **Brackets** need to be around 2 font sizes bigger

## Configuration

### math_writer.yaml
```yaml
main_script:
    m_type: vc::lua_script_t
    m_source_path: ./main.lua
```

This tells the virt_composer to load and execute `main.lua` as the main script.

### Font Configuration
Fonts are loaded from the `fonts/` directory. The main font set includes AMS math fonts for proper mathematical symbol rendering.

## Building

### Linux
```bash
make -f linux.makefile
./a.out
```

### Windows
```bash
make -f windows.makefile
./a.exe
```

### Dependencies
- G++ (C++20 support)
- GLFW
- OpenGL
- Lua development libraries
- fkyaml (YAML parsing)

## Current Status (from git log)

Recent commits:
- `e586911` adding mexpr drawing
- `26c57d4` boxes now pass wrap border, this is the solution that may also work with clickable areas
- `f22ca69` added wrapping
- `2701e8c` all math drawing now work as expected
- `024690d` wip math expr
- `4562508` added mexpr to lua and now I can draw mathematical expressions from inside lua
- `a973e3c` WIP - moving the drawing partially into Lua

The project appears to be in active development with the math expression drawing functionality recently added and working.

## TODO Items (from TODO.md)

### Main Tasks
- Restructure the entire project
- Add virt_composer with imgui
- Change the drawing and entire logic to be saved in:
  - yaml files
  - font files
  - lua files

### Tree Experiment - "copac"
- Need a node structure of virt_objects maybe? such that they can be controlled from lua
- Make them spit out latex for now

## Key Files and Their Roles

### Entry Point
- **main.cpp**: Initializes ImGui, creates virt_composer state, registers composables, loads config, and runs the main loop

### Core Drawing
- **char_draw_composer.h**: Font management and character rendering
- **math_expr_composer.h**: Math expression layout and composition

### Lua Interface
- **main.lua**: Test drawing functions, creates sample ASTs and renders them
- **ast.lua**: AST node types, creation, and manipulation
- **char.lua**: Character drawing utilities for Lua
- **mexpr.lua**: Math expression utilities for Lua
- **transforms.lua**: AST transformation utilities

## Development Notes

### Important Patterns

1. **Namespace Usage**: The code uses namespaces extensively:
   - `vc` for virt_composer
   - `drawc` for char_draw_composer
   - `mexpr` for math_expr_composer

2. **Error Handling**: Uses `ASSERT_FN` for error checking, which appears to be a custom assert macro

3. **Object Types**: Uses a type registration system with `VIRT_COMPOSER_REGISTER_TYPE`

4. **Lua Integration**: Uses `VC_REGISTER_MEMBER_FUNCTION` and `VC_REGISTER_MEMBER_OBJECT` to expose C++ objects to Lua

### Debugging
The project uses a custom debug system:
- `DBG_SCOPE()` for scoped debugging
- `DBG()` for debug messages
- Logs are written to `logfile.log` and rotated to `logfile.old.log`

### Known Issues/Observations

From code comments:
- Need to figure out gestures for operations (main.cpp:64-68)
- Need to implement save/load options (main.cpp:67)

## Usage

Currently, the application:
1. Initializes ImGui with a full-screen window
2. Loads the main Lua script
3. Calls `test_init()` to initialize fonts
4. In the main loop, calls `test_draw()` to render test expressions
5. Displays ImGui metrics window

The test drawing shows various math expressions including:
- Simple equations: `a = 10 + (-10)`
- Complex nested expressions
- Superscripts and subscripts
- Fractions
- Big operators (sum, integral)
- Bracketed expressions

## Future Work

Based on TODO.md and code comments:
1. Complete the project restructuring
2. Move all hardcoded behaviors to Lua scripts
3. Implement undo/redo functionality
4. Implement gesture-based editing
5. Add save/load functionality
6. Implement the node structure for virt_objects controllable from Lua
7. Add LaTeX export/import
8. Implement the copac experiment (tree structure)

## Code Style Guidelines

- **Maximum line width**: 100 characters
- **Status**: `ast.lua` and `mexpr.lua` have been reformatted to comply with the 100-character limit

### Line Wrapping Convention
When a line exceeds 100 characters, it should be broken with continuation lines indented by **2 additional levels** (8 spaces) from the start of the previous line.

**Example:**
```lua
-- If a line starts at 4 spaces (1 level):
local result = some_long_function_call(arg1, arg2, arg3) ..
        -- continuation at 12 spaces (3 levels: original 1 + 2)
        another_long_function(arg4, arg5)
```

## License

The project includes:
- LICENSE file (MIT-like license)
- Fonts have their own licenses (Knuth License, License for dsrom) in `fonts/licences/`

---

*Last updated: July 1, 2026*
*Project status: Active development*