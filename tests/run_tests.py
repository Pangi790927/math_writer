#!/usr/bin/env python3
"""
run_tests.py - automated test runner for math_writer.

The actual test LOGIC lives in Lua (tests/lua/*.lua, each defining a run_test() that returns
true/false) since that's what actually exercises mformula_new/mexpru/mformula_latex the same way
the real app does. This script is the orchestrator: it builds a small headless C++ harness
(tests/harness/test_harness.cpp - loads the real virt_composer/char_draw_composer/
math_expr_composer registration, no windowing/GLFW needed) once, incrementally, then runs it once
per Lua test file and reports a pass/fail summary.

Usage:
    python tests/run_tests.py                  # build (if needed) and run every test
    python tests/run_tests.py test_navigation   # run only tests whose filename contains this
    python tests/run_tests.py --no-build        # skip the build step (assumes it's up to date)
    python tests/run_tests.py --list            # list discovered tests without running them

Exit code is 0 if every test passed, 1 otherwise (including build failures) - suitable for CI.
"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = Path(__file__).resolve().parent
LUA_DIR = TESTS_DIR / "lua"
HARNESS_DIR = TESTS_DIR / "harness"
BUILD_DIR = HARNESS_DIR / "build"

UTILS = REPO_ROOT.parent / "utils"
IMGUI = REPO_ROOT.parent / "imgui"
IMPLOT = REPO_ROOT.parent / "implot"

INCLUDES = [
    f"/I{UTILS}",
    f"/I{UTILS / 'ap'}",
    f"/I{UTILS / 'co'}",
    f"/I{UTILS / 'generic'}",
    f"/I{REPO_ROOT}",
    f"/I{IMGUI}",
    f"/I{IMGUI / 'backends'}",
    f"/I{IMPLOT}",
    f"/I{REPO_ROOT / 'old'}",
]

CXX_FLAGS = [
    "/EHs", "/await:strict", "/std:c++20", "/Zi", "/MD", "/Zc:preprocessor",
    "/DVIRT_COMPOSER_ENABLE_LUA_IO=1",
]

# (source .cpp, display name) - compiled once each into BUILD_DIR, incrementally (skipped if the
# resulting .obj is newer than its source). These are the same translation units main.exe itself
# links (see ../windows.makefile) - reused here rather than duplicated, so the harness always
# reflects whatever the real app would actually do.
HARNESS_SOURCES = [
    (UTILS / "virt_composer.cpp", "virt_composer"),
    (IMGUI / "imgui.cpp", "imgui"),
    (IMGUI / "imgui_draw.cpp", "imgui_draw"),
    (IMGUI / "imgui_tables.cpp", "imgui_tables"),
    (IMGUI / "imgui_widgets.cpp", "imgui_widgets"),
    (IMGUI / "imgui_demo.cpp", "imgui_demo"),
    (HARNESS_DIR / "test_harness.cpp", "test_harness"),
]

HARNESS_EXE = BUILD_DIR / "test_harness.exe"


def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def compile_one(src: Path, obj: Path, force: bool = False) -> bool:
    """Compiles src -> obj if obj is missing, older than src, or force is set. Returns False on
    failure. mtime-vs-src is the only staleness check - it has no idea about headers src #includes
    (math_expr_composer.h, char_draw_composer.h, ...), so editing ONLY a header a .cpp depends on
    never looks stale by this check alone - `--rebuild` (force=True here) is the only way to force
    a real recompile in that case. Found 2026-09-04: math_expr_composer.h picked up a real change,
    test_harness.cpp itself didn't, so its .obj stayed silently stale even under --rebuild, since
    build_harness() computed `force` but never actually passed it down into this function."""
    if not force and obj.exists() and obj.stat().st_mtime >= src.stat().st_mtime:
        return True
    print(f"  compiling {src.name} ...")
    cmd = ["cl", "/c", *CXX_FLAGS, *INCLUDES, str(src), f"/Fo{obj}"]
    result = run(cmd, cwd=BUILD_DIR)
    if result.returncode != 0:
        print(f"FAILED to compile {src}:")
        print(result.stdout)
        print(result.stderr)
        return False
    return True


def build_harness(force: bool) -> bool:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    print("Building test harness...")

    objs = []
    any_rebuilt = force or not HARNESS_EXE.exists()
    for src, name in HARNESS_SOURCES:
        if not src.exists():
            print(f"FAILED: expected source not found: {src}")
            return False
        obj = BUILD_DIR / f"{name}.obj"
        was_up_to_date = obj.exists() and obj.stat().st_mtime >= src.stat().st_mtime and not force
        if not compile_one(src, obj, force=force):
            return False
        if not was_up_to_date:
            any_rebuilt = True
        objs.append(obj)

    if not any_rebuilt and HARNESS_EXE.exists():
        print("  harness up to date, skipping link.")
        return True

    print("  linking test_harness.exe ...")
    cmd = [
        "cl", *CXX_FLAGS, *(str(o) for o in objs),
        f"/Fe{HARNESS_EXE}", "/link", "gdi32.lib", "glfw3.lib", "opengl32.lib",
    ]
    result = run(cmd, cwd=BUILD_DIR)
    if result.returncode != 0:
        print("FAILED to link test_harness.exe:")
        print(result.stdout)
        print(result.stderr)
        return False
    print("  build OK.")
    return True


def discover_tests(filter_substr: str | None) -> list[Path]:
    tests = sorted(LUA_DIR.glob("*.lua"))
    if filter_substr:
        tests = [t for t in tests if filter_substr in t.name]
    return tests


def run_one_test(lua_path: Path) -> tuple[bool, str]:
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yaml", delete=False, dir=str(BUILD_DIR)
    ) as f:
        yaml_path = Path(f.name)
        lua_path_yaml = str(lua_path).replace("\\", "/")
        f.write(
            "main_script:\n"
            "    m_type: vc::lua_script_t\n"
            f"    m_source_path: {lua_path_yaml}\n"
        )
    try:
        result = run([str(HARNESS_EXE), str(yaml_path)], cwd=REPO_ROOT, timeout=120)
        passed = result.returncode == 0 and "HARNESS: PASSED" in result.stdout
        output = result.stdout + result.stderr
        return passed, output
    except subprocess.TimeoutExpired:
        return False, "TIMED OUT after 120s"
    finally:
        yaml_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("filter", nargs="?", default=None, help="only run tests whose filename contains this substring")
    parser.add_argument("--no-build", action="store_true", help="skip building/rebuilding the harness")
    parser.add_argument("--rebuild", action="store_true", help="force a full rebuild of the harness")
    parser.add_argument("--list", action="store_true", help="list discovered tests and exit")
    parser.add_argument("-v", "--verbose", action="store_true", help="print full harness output for every test, not just failures")
    args = parser.parse_args()

    tests = discover_tests(args.filter)
    if args.list:
        for t in tests:
            print(t.name)
        return 0

    if not tests:
        print("No tests matched." if args.filter else "No tests found in tests/lua/.")
        return 1

    if not args.no_build:
        if not build_harness(force=args.rebuild):
            return 1
        print()

    if not HARNESS_EXE.exists():
        print(f"Harness not found at {HARNESS_EXE} - run without --no-build first.")
        return 1

    print(f"Running {len(tests)} test(s)...\n")
    results = []
    for lua_path in tests:
        passed, output = run_one_test(lua_path)
        status = "PASS" if passed else "FAIL"
        print(f"[{status}] {lua_path.name}")
        if args.verbose or not passed:
            for line in output.strip().splitlines():
                print(f"    {line}")
        results.append((lua_path.name, passed))

    print()
    failed = [name for name, ok in results if not ok]
    print(f"{len(results) - len(failed)}/{len(results)} passed.")
    if failed:
        print("Failed: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
