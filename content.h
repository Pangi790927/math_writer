#ifndef CONTENT_H
#define CONTENT_H

/* The app has the content window, this content window contains boxes with, well, content. */

#define CBOX_INCR   20
#define CBOX_LEFT   3
#define CBOX_RIGHT  4
#define CBOX_HORIZ  2
#define CBOX_TOP    2

struct cbox_t {
    int widht = 1;
    int height = 1;
};

inline int content_init();
inline void content_uninit();

/* IMPLEMENTATION
 * =================================================================================================
 */

inline int content_init() {
    return 0;
}

inline int content_draw() {
    auto *io = &ImGui::GetIO();
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    auto top    = ImVec2(CBOX_INCR * CBOX_LEFT, 0);
    auto bottom = ImVec2(CBOX_INCR * CBOX_LEFT, io->DisplaySize.y);
    draw_list->AddLine(top, bottom, 0xff'00ffff, 1);

    auto box_min = ImVec2(CBOX_INCR * (CBOX_LEFT + CBOX_RIGHT), CBOX_INCR * (CBOX_TOP));
    auto box_max = ImVec2(CBOX_INCR * (CBOX_LEFT + CBOX_RIGHT + 10), CBOX_INCR * (CBOX_TOP + 3));
    auto line_start = ImVec2(CBOX_INCR * CBOX_LEFT,                CBOX_INCR * (CBOX_TOP + 1.5));
    auto line_end   = ImVec2(CBOX_INCR * (CBOX_LEFT + CBOX_RIGHT), CBOX_INCR * (CBOX_TOP + 1.5));
    draw_list->AddCircle(line_start, CBOX_INCR/2, 0xff'00ffff);
    draw_list->AddLine(line_start, line_end, 0xff'00ffff, 1);
    draw_list->AddRect(box_min, box_max, 0xff'000000, CBOX_INCR / 2, 0, 4);
    draw_list->AddRectFilled(box_min, box_max, 0xff'00ffff, CBOX_INCR / 2);
    return 0;
}

inline void content_uninit() {}

#endif
