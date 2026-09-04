// Automated test harness: loads a Lua test script (via a YAML config, see run_tests.py) through
// the same virt_composer/char_draw_composer/math_expr_composer registration the real app uses,
// then calls that script's own run_test() and reports PASS/FAIL. No windowing/rendering/GLFW
// needed - just the Lua<->C++ interop layer the tests actually exercise (mexpr_t construction,
// bounding boxes, parent pointers, etc.) - see tests/run_tests.py for how this gets invoked.
#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS
#include "char_draw_composer.h"
#include "math_expr_composer.h"
#include "virt_composer_end.h"
#include <cstdio>

namespace vc = virt_composer;
namespace charc = char_draw_composer;
namespace mexpr = math_expr_composer;

int main(int argc, char **argv) {
    const char *yaml_path = argc > 1 ? argv[1] : "test_u_capture.yaml";

    ImGui::CreateContext();

    auto vs = vc::create_state();
    if (!vs) { printf("create_state failed\n"); return 1; }
    if (charc::register_meta(vs.get()) != vc::VC_ERROR_OK) { printf("charc register_meta failed\n"); return 1; }
    if (mexpr::register_meta(vs.get()) != vc::VC_ERROR_OK) { printf("mexpr register_meta failed\n"); return 1; }

    auto perr = vc::parse_config(vs.get(), yaml_path);
    if (perr != vc::VC_ERROR_OK) { printf("parse_config failed: %d\n", (int)perr); return 1; }

    auto [ok, err] = vc::call_lua<bool>(vs.get(), "run_test");
    if (err != vc::VC_ERROR_OK) { printf("call_lua failed: %d\n", (int)err); return 1; }
    printf(ok ? "HARNESS: PASSED\n" : "HARNESS: FAILED\n");
    return ok ? 0 : 1;
}
