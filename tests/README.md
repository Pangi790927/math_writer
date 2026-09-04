# Automated tests

```bash
python tests/run_tests.py              # build (if needed) + run everything
python tests/run_tests.py navigation   # only tests whose filename contains "navigation"
python tests/run_tests.py --no-build   # skip the build step (assumes it's already up to date)
python tests/run_tests.py --rebuild    # force a full rebuild of the harness
python tests/run_tests.py --list       # list discovered tests without running them
python tests/run_tests.py -v           # print full harness output for every test, not just failures
```

Exit code is 0 if every test passed, 1 otherwise - safe to use as a CI gate.

## How it fits together

- **`tests/lua/*.lua`** - the actual test logic. Each file defines a `run_test()` returning
  `true`/`false`, and requires `scripts/*.lua` the same way the real app does (`mformula_new`,
  `mexpru`, `mformula_latex`, ...). This is where you add new tests.
- **`tests/harness/test_harness.cpp`** - a small headless C++ program that registers the same
  `virt_composer`/`char_draw_composer`/`math_expr_composer` Lua bindings the real app does (no
  windowing/GLFW/rendering needed - just the Lua↔C++ interop layer the tests actually exercise),
  loads one Lua file, and calls its `run_test()`.
- **`tests/run_tests.py`** - builds the harness incrementally (reusing the same translation units
  `main.exe` itself links - see `../windows.makefile` - so the harness always reflects whatever the
  real app would actually do) and runs it once per `tests/lua/*.lua` file.

## Adding a new test

Drop a new `tests/lua/test_whatever.lua` with a `run_test()` function (see any existing file for
the pattern - `package.path`, `char.load_font_set()`, building nodes via `mexpru`/`mformula_new`/
`mformula_latex`, `print("FAIL: ...")` + `return false` on a failed check, `return true` at the
end). It's picked up automatically, no registration needed.
