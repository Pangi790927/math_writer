#ifndef DEFINES_H
#define DEFINES_H

#include "mathd.h"

struct define_box_t;
using define_box_p = std::shared_ptr<define_box_t>;

inline int defines_init();
inline define_box_p defines_create();

/* IMPLEMENTATION
 * =================================================================================================
 */

inline int defines_init() {
    return 0;
}

inline define_box_p defines_create() {
    return std::make_shared<define_box_t>();
}

struct define_box_t : public cbox_i {
    void update() override {

    }

    std::pair<float, float> draw_area(float width_limit, float height_limit) override {
        return {600.0f, 100.0f};
    }

    void draw(ImVec2 pos, float width_limit, float height_limit) override {
        // ImDrawList* draw_list = ImGui::GetWindowDrawList();
        // draw_list->AddRect(pos, pos + ImVec2(600, 100), 0xff'00aa00, 0, 0, 1);
    }
};

#endif
