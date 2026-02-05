#ifndef MATH_TYPES_H
#define MATH_TYPES_H

/*! Math Type
 * 
 * Building block for expressions. Those types are used to create a versatile base for the
 * expressions and also decouple how the operators work from how the objects respond to said
 * operation.
 */

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
