#ifndef CONTENT_H
#define CONTENT_H

/* The app has the content window, this content window contains boxes with, well, content. */

#define CBOX_INCR   20
#define CBOX_LEFT   3
#define CBOX_RIGHT  4
#define CBOX_HORIZ  2
#define CBOX_TOP    1
#define CBOX_INF    1000000000

/*! This type will be inherited by the content windows: comment window, definition window and
 * formula window or any other window */
struct cbox_i {
    virtual ~cbox_i() {}

    /*! @return (width, heigth) of the draw area for this object */
    virtual std::pair<float, float> draw_area(float width_limit, float height_limit) = 0;

    /*! draw the object
     * @param pos - the positionm left top of the box to be drawn
     * @param width - the width of the drawing area
     * @param height - the height of the drawing area */
    virtual void draw(ImVec2 pos, float width_limit, float height_limit) = 0;

    /*! this is the active object and it needs updating */
    virtual void update() = 0;
};

struct cbox_t {
    float width = 1;
    float height = 1;
    bool is_active = false;

    std::shared_ptr<cbox_i> obj = nullptr;
};

inline int content_init();
inline void content_uninit();

inline void content_update();
inline void content_draw();

/* IMPLEMENTATION
 * =================================================================================================
 */

inline std::vector<cbox_t> cboxes;

inline const float WIN_LEFT_OFFSET = CBOX_INCR * (CBOX_LEFT + CBOX_RIGHT);

inline int content_init() {
    cboxes.push_back(cbox_t{ .width = 25 * CBOX_INCR, .height = 3 * CBOX_INCR });
    cboxes.push_back(cbox_t{ .width = 0 * CBOX_INCR, .height = 0 * CBOX_INCR });
    cboxes.push_back(cbox_t{ .width = 20 * CBOX_INCR, .height = 2 * CBOX_INCR });
    return 0;
}

inline void content_update() {
    bool is_left_clicked = ImGui::IsMouseClicked(ImGuiMouseButton_Left);
    auto mouse_pos = ImGui::GetMousePos();

    /* First we figure out the active window */
    float offset = CBOX_INCR * CBOX_TOP;
    for (auto &cb : cboxes) {
        auto box_min = ImVec2(WIN_LEFT_OFFSET, offset);
        auto box_max = ImVec2(WIN_LEFT_OFFSET + cb.width + CBOX_INCR, offset + cb.height + CBOX_INCR);

        if (is_left_clicked) {
            if (box_min.x <= mouse_pos.x && mouse_pos.x <= box_max.x &&
                    box_min.y <= mouse_pos.y && mouse_pos.y <= box_max.y)
            {
                cb.is_active = true;
            }
            else
                cb.is_active = false;
        }
        offset += CBOX_INCR * (CBOX_TOP + 1) + cb.height;
    }

    /* Second we update that window and all draw areas */
    ImVec2 win_end = ImGui::GetContentRegionMax();
    offset = CBOX_INCR * CBOX_TOP;
    for (auto &cb : cboxes) {
        auto box_min = ImVec2(WIN_LEFT_OFFSET, offset);

        if (cb.is_active && cb.obj)
            cb.obj->update();

        float win_max_w = win_end.x - WIN_LEFT_OFFSET - CBOX_INCR;
        if (cb.obj) {
            auto [w, h] = cb.obj->draw_area(win_max_w, CBOX_INF);
            cb.width = w;
            cb.height = h;
        }

        offset += CBOX_INCR * (CBOX_TOP + 1) + cb.height;
    }
}

inline void content_draw() {
    auto *io = &ImGui::GetIO();
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    uint32_t sides_color  = 0xff'777777;
    uint32_t sides_color2 = 0xff'333333;
    uint32_t fill_color   = 0xff'AAAAAA;

    auto top    = ImVec2(CBOX_INCR * CBOX_LEFT, 0);
    auto bottom = ImVec2(CBOX_INCR * CBOX_LEFT, io->DisplaySize.y);
    draw_list->AddLine(top, bottom, sides_color, 1);

    float offset = CBOX_INCR * CBOX_TOP;
    ImVec2 win_end = ImGui::GetContentRegionMax();

    /* Assuming content_update was called we call all the draw functions */
    for (auto &cb : cboxes) {
        float hb = cb.height;
        float wb = cb.width;
        auto line_start = ImVec2(CBOX_INCR * CBOX_LEFT, (hb + CBOX_INCR) / 2 + offset);
        auto line_end   = ImVec2(WIN_LEFT_OFFSET      , (hb + CBOX_INCR) / 2 + offset);
        draw_list->AddCircle(line_start, CBOX_INCR/2, sides_color);
        draw_list->AddLine(line_start, line_end, sides_color, 1);

        auto box_min = ImVec2(WIN_LEFT_OFFSET                    , offset);
        auto box_max = ImVec2(WIN_LEFT_OFFSET + wb + CBOX_INCR   , offset + hb + CBOX_INCR);
        draw_list->AddRect(box_min, box_max, cb.is_active ? sides_color2 : sides_color,
                CBOX_INCR / 4, 0, cb.is_active ? 8 : 4);
        draw_list->AddRectFilled(box_min, box_max, fill_color, CBOX_INCR / 4);

        auto box_pos = ImVec2(WIN_LEFT_OFFSET + CBOX_INCR/2., offset + CBOX_INCR/2.);
        if (cb.obj)
            cb.obj->draw(box_pos, wb, hb);

        offset += CBOX_INCR * (CBOX_TOP + 1) + hb;
    }

    /* TODO: if this is clicked, add items */
    auto circle_center = ImVec2(CBOX_INCR * CBOX_LEFT, offset);
    draw_list->AddCircle(circle_center, CBOX_INCR/2, sides_color);

    auto line_end   = ImVec2(CBOX_INCR * CBOX_LEFT + CBOX_INCR/2., offset);
    auto line_start = ImVec2(CBOX_INCR * CBOX_LEFT - CBOX_INCR/2., offset);
    draw_list->AddLine(line_start, line_end, sides_color, 1);
}

inline void content_uninit() {}

#endif
