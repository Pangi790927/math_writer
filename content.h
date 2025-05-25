#ifndef CONTENT_H
#define CONTENT_H

/* The app has the content window, this content window contains boxes with, well, content. */

#define CBOX_INCR   20
#define CBOX_LEFT   1.5
#define CBOX_RIGHT  2
#define CBOX_HORIZ  2
#define CBOX_TOP    2
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

        auto menu_min = ImVec2(WIN_LEFT_OFFSET + cb.width,             offset - CBOX_INCR);
        auto menu_max = ImVec2(WIN_LEFT_OFFSET + cb.width + CBOX_INCR, offset);

        if (is_left_clicked) {
            if (menu_min.x <= mouse_pos.x && mouse_pos.x <= menu_max.x &&
                    menu_min.y <= mouse_pos.y && mouse_pos.y <= menu_max.y)
            {
                ImGui::OpenPopup("PopUp");
                ImGui::SetNextWindowPos(ImVec2(menu_min.x, menu_max.y));
            }

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

    if (ImGui::BeginPopup("PopUp"))
    {
        ImGui::Text("options:");
        ImGui::Separator();
        if (ImGui::Button("OK")) {
            /* do something*/
        }
        ImGui::Separator();
        if (ImGui::Button("NOK")) {
            /* do something else*/
        }
        ImGui::EndPopup();
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

    /* TODO: if this is clicked, add items */
    if (mouse_pos.x < WIN_LEFT_OFFSET) {
    }
}

inline void content_draw() {
    auto *io = &ImGui::GetIO();
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    uint32_t sides_color  = 0xff'777777;
    uint32_t sides_color2 = 0xff'3f3f3f;
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

        // Anchor to the left branch
        auto line_start = ImVec2(CBOX_INCR * CBOX_LEFT, (hb + CBOX_INCR) / 2 + offset);
        auto line_end   = ImVec2(WIN_LEFT_OFFSET      , (hb + CBOX_INCR) / 2 + offset);
        draw_list->AddCircle(line_start, CBOX_INCR/2, sides_color);
        draw_list->AddLine(line_start, line_end, sides_color, 1);

        // Menu drawing
        auto menu_min = ImVec2(WIN_LEFT_OFFSET + wb,             offset - CBOX_INCR);
        auto menu_max = ImVec2(WIN_LEFT_OFFSET + wb + CBOX_INCR, offset);
        draw_list->AddRect(menu_min, menu_max, sides_color, CBOX_INCR / 8, 0, 4);
        draw_list->AddRectFilled(menu_min, menu_max, fill_color, CBOX_INCR / 8);
        auto line1_start = ImVec2(WIN_LEFT_OFFSET + wb + CBOX_INCR/5., offset - CBOX_INCR*4/6.);
        auto line2_start = ImVec2(WIN_LEFT_OFFSET + wb + CBOX_INCR/5., offset - CBOX_INCR*3/6.);
        auto line3_start = ImVec2(WIN_LEFT_OFFSET + wb + CBOX_INCR/5., offset - CBOX_INCR*2/6.);
        draw_list->AddLine(line1_start, line1_start + ImVec2(CBOX_INCR*3/5., 0), sides_color2, 1);
        draw_list->AddLine(line2_start, line2_start + ImVec2(CBOX_INCR*3/5., 0), sides_color2, 1);
        draw_list->AddLine(line3_start, line3_start + ImVec2(CBOX_INCR*3/5., 0), sides_color2, 1);

        // Box drawing
        auto box_min = ImVec2(WIN_LEFT_OFFSET                    , offset);
        auto box_max = ImVec2(WIN_LEFT_OFFSET + wb + CBOX_INCR   , offset + hb + CBOX_INCR);
        draw_list->AddRect(box_min, box_max, cb.is_active ? sides_color2 : sides_color,
                CBOX_INCR / 4, 0, cb.is_active ? 8 : 4);
        draw_list->AddRectFilled(box_min, box_max, fill_color, CBOX_INCR / 4);

        // Box contents
        auto box_pos = ImVec2(WIN_LEFT_OFFSET + CBOX_INCR/2., offset + CBOX_INCR/2.);
        if (cb.obj)
            cb.obj->draw(box_pos, wb, hb);

        offset += CBOX_INCR * (CBOX_TOP + 1) + hb;
    }

    auto mouse_pos = ImGui::GetMousePos();
    if (mouse_pos.x < WIN_LEFT_OFFSET) {
        auto circle_center = ImVec2(CBOX_INCR * CBOX_LEFT, mouse_pos.y);
        draw_list->AddCircle(circle_center, CBOX_INCR/2, sides_color);

        auto line_start = ImVec2(CBOX_INCR * CBOX_LEFT - CBOX_INCR/2., mouse_pos.y);
        auto line_end   = ImVec2(mouse_pos.x, mouse_pos.y);
        draw_list->AddLine(line_start, line_end, sides_color, 1);
    }
}

inline void content_uninit() {}

#endif
