#ifndef CONTENT_H
#define CONTENT_H

/* The app has the content window, this content window contains boxes with, well, content. */

#define CBOX_INCR   20
#define CBOX_LEFT   3
#define CBOX_RIGHT  4
#define CBOX_HORIZ  2
#define CBOX_TOP    2

struct cbox_t {
    int width = 1;
    int height = 1;
};

inline int content_init();
inline void content_uninit();

/* IMPLEMENTATION
 * =================================================================================================
 */

inline std::vector<cbox_t> cboxes;

inline int content_init() {
    cboxes.push_back(cbox_t{ .width = 50, .height = 3 });
    cboxes.push_back(cbox_t{ .width = 30, .height = 1 });
    cboxes.push_back(cbox_t{ .width = 40, .height = 2 });
    return 0;
}

inline int content_draw() {
    auto *io = &ImGui::GetIO();
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    uint32_t sides_color = 0xff'777777;
    uint32_t fill_color = 0xff'AAAAAA;

    auto top    = ImVec2(CBOX_INCR * CBOX_LEFT, 0);
    auto bottom = ImVec2(CBOX_INCR * CBOX_LEFT, io->DisplaySize.y);
    draw_list->AddLine(top, bottom, sides_color, 1);

    float offset = CBOX_INCR * CBOX_TOP;
    for (auto &cbox : cboxes) {
        float hb = cbox.height;
        float wb = cbox.width;
        auto line_start = ImVec2(CBOX_INCR * CBOX_LEFT,                CBOX_INCR * hb / 2 + offset);
        auto line_end   = ImVec2(CBOX_INCR * (CBOX_LEFT + CBOX_RIGHT), CBOX_INCR * hb / 2 + offset);
        draw_list->AddCircle(line_start, CBOX_INCR/2, sides_color);
        draw_list->AddLine(line_start, line_end, sides_color, 1);

        auto box_min = ImVec2(CBOX_INCR * (CBOX_LEFT + CBOX_RIGHT), offset);
        auto box_max = ImVec2(CBOX_INCR * (CBOX_LEFT + CBOX_RIGHT + wb), CBOX_INCR * hb + offset);
        draw_list->AddRect(box_min, box_max, sides_color, CBOX_INCR / 4, 0, 4);
        draw_list->AddRectFilled(box_min, box_max, fill_color, CBOX_INCR / 4);
        offset += CBOX_INCR * (CBOX_TOP + hb);
    }
    return 0;
}

inline void content_uninit() {}

#endif
