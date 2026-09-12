/*! test_harness.cpp - runs one Lua test against the real interop layer, headless.
 *
 * Core: a test here talks to the SAME C++ the application talks to. The composers are registered
 * onto a real virt_state_t exactly as main.cpp registers them, so mexpr_t construction, bounding
 * boxes and parent pointers behave under test the way they behave in the app - which is the only
 * reason a green suite means anything. A test script provides `run_test`, and its boolean return
 * becomes this process's exit code.
 *
 * Core: THE REGISTERED SET MUST TRACK main.cpp's. Every composer the scripts may reach has to be
 * listed below, and a composer added there and forgotten here does not fail loudly - the binding is
 * simply absent, `vc.whatever` is nil, and whichever test touches it fails for a reason that looks
 * like a Lua bug. path_composer was added 2026-09-12 for exactly that reason:
 * scripts/transforms.lua enumerates its plugin folder through vc.path_list_dir, and without this
 * registration the harness would load no plugins at all while the app loaded them fine.
 *
 * Detail: the test to run arrives as a YAML config path in argv[1] - tests/run_tests.py writes one
 * per script - and defaults to test_u_capture.yaml when none is given. Result goes to stdout as
 * "HARNESS: PASSED" or "HARNESS: FAILED"; run_tests.py checks both that string and the exit code,
 * so a crash before the print cannot read as a pass.
 *
 * Detail: no windowing, no rendering, no GLFW. An ImGui context is created because the composers
 * expect one to exist, but nothing is ever drawn. That is what makes the suite runnable with no
 * display - and it is also the known blind spot: nothing here exercises a draw path, which is how a
 * nil-call in one went unnoticed until it reached the screen (see test_no_use_before_define.lua).
 *
 * Note: path resolution differs from the app's. This binary lives in tests/harness/build/ but is
 * run with the repository root as its working directory, so anything cwd-relative (package.path's
 * ./scripts/?.lua) resolves against the repo while anything resolved against the executable's own
 * directory does not.
 * @date 2026-09-12 02:20 */
#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS
#include "char_draw_composer.h"
#include "math_expr_composer.h"
#include "path_composer.h"
#include "virt_composer_end.h"
#include <cstdio>

namespace vc = virt_composer;
namespace charc = char_draw_composer;
namespace mexpr = math_expr_composer;
namespace pathc = path_composer;

int main(int argc, char **argv) {
    const char *yaml_path = argc > 1 ? argv[1] : "test_u_capture.yaml";

    ImGui::CreateContext();

    auto vs = vc::create_state();
    if (!vs) { printf("create_state failed\n"); return 1; }
    if (charc::register_meta(vs.get()) != vc::VC_ERROR_OK) { printf("charc register_meta failed\n"); return 1; }
    if (mexpr::register_meta(vs.get()) != vc::VC_ERROR_OK) { printf("mexpr register_meta failed\n"); return 1; }
    if (pathc::register_meta(vs.get()) != vc::VC_ERROR_OK) { printf("pathc register_meta failed\n"); return 1; }

    auto perr = vc::parse_config(vs.get(), yaml_path);
    if (perr != vc::VC_ERROR_OK) { printf("parse_config failed: %d\n", (int)perr); return 1; }

    auto [ok, err] = vc::call_lua<bool>(vs.get(), "run_test");
    if (err != vc::VC_ERROR_OK) { printf("call_lua failed: %d\n", (int)err); return 1; }
    printf(ok ? "HARNESS: PASSED\n" : "HARNESS: FAILED\n");
    return ok ? 0 : 1;
}
