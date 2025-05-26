#ifndef MATHT_H
#define MATHT_H

/* Math Type */

struct matht_t {
    mathv_p symb;
};

using matht_p = std::shared_ptr<matht_t>;

inline matht_p create_math_type();

/* IMPLEMENTATION
 * =================================================================================================
 */

inline matht_p create_math_type() {
    return std::make_shared<matht_t>();
}

#endif
