#ifndef APP_MODE_H
#define APP_MODE_H

/*!
 * app_mode.h - which of the two instances this process is, and where its files live.
 *
 * Two modes, chosen by argv (main.cpp):
 *
 *   PRESENTATION (no arguments) - the real app, the one a person runs. Visible window, no debug
 *       input pipe, files where they have always been: math_writer.save, logfile.log,
 *       input_history.log, imgui.ini.
 *
 *   TESTING ("--test") - the one an automated session drives. Window never shown, debug input pipe
 *       listening, and EVERY file it touches moved under test_run/.
 *
 * Requested 2026-09-05: "what I run is different than what you run, as such we won't intervene in
 * our tests". The two used to share everything, and it showed - a headless test run would overwrite
 * math_writer.save with whatever the test had typed, so nearly every run in that session ended in a
 * `git checkout -- math_writer.save` to rescue the real document. The debug pipe's fixed port
 * (47821) is the other collision: a second instance cannot bind it, so a presentation instance left
 * running would silently break every test, and a test instance would answer commands meant for
 * nothing at all.
 *
 * Separation is by PREFIX rather than by per-file flags: one directory to delete, one to gitignore,
 * and a new data file added later is separated automatically as long as it goes through
 * data_prefix(). Lua reads it via vc.app_data_prefix() and does its own concatenation - the paths
 * themselves live in the Lua that owns each file, not here.
 */

#include "virt_composer.h"

#include <string>

namespace app_mode {

namespace vc = virt_composer;
namespace appm = app_mode;

inline bool g_testing = false;

/*! Everything the testing instance writes goes under here. Trailing slash included so callers can
 * concatenate without knowing whether they are separated or not. */
inline const char *TESTING_PREFIX = "test_run/";

inline void set_testing(bool on) { g_testing = on; }
inline bool app_is_testing() { return g_testing; }

/*! "" in presentation mode, "test_run/" in testing mode. */
inline std::string app_data_prefix() {
    return g_testing ? std::string(TESTING_PREFIX) : std::string();
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> app_tab_funcs = {
        {"app_is_testing",  vc::luaw_function_wrapper<app_is_testing>},
        {"app_data_prefix", vc::luaw_function_wrapper<app_data_prefix>},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, app_tab_funcs));

    return vc::VC_ERROR_OK;
}

} /* namespace app_mode */

#endif /* APP_MODE_H */
