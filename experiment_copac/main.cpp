#ifdef _MSC_VER
# define NOMINMAX
#endif

#include <iostream>

#include "ast_composer.h"
#include "virt_composer_end.h"

namespace astc = ast_composer;
namespace vc = virt_composer;

int main(int argc, char const *argv[]) {

    auto vs = vc::create_state();
    ASSERT_FN(CHK_PTR(vs));
    ASSERT_FN(astc::register_meta(vs.get()));
    ASSERT_FN(vc::parse_config(vs.get(), "copac.yaml"));
    auto [ret, err] = vc::call_lua<int>(vs.get(), "main");
    ASSERT_FN(ret);
    ASSERT_FN(err);
    return 0;
}