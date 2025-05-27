#ifndef COMMENTS_H
#define COMMENTS_H

#include "debug.h"
#include "content.h"
#include "chars.h"

struct comment_box_t;
using comment_box_p = std::shared_ptr<comment_box_t>;

/*! This function initializes this comment module. Can be called multiple times.
 * @return 0 on success, negative value on error */
inline int comments_init();
inline comment_box_p comments_create();

/* IMPLEMENTATION
 * =================================================================================================
 */

inline int comments_init() {
    return 0;
}

inline comment_box_p comments_create() {
    return std::make_shared<comment_box_t>();
}

struct comment_box_t : public cbox_i {
    float max_width = 0;
    int line_count = 0;
    std::vector<char_t> chars;

    int cursor_pos = 0;
    bool is_italic = false;
    bool is_bold = false;
    char_font_lvl_e flvl = FONT_LVL_SUB2;
    float comments_line_height[FONT_LVL_CNT] = {0.0f};
    float comments_pos_increment[FONT_LVL_CNT] = {0.0f};

    void update() override {
        /* TODO: add some indicators for italic, bold, etc */
        // ImGui::SetItemKeyOwner(ImGuiMod_Alt);
        // ImGui::SetItemKeyOwner(ImGuiMod_Shift);
        auto *io = &ImGui::GetIO();
        bool is_ctrl = ImGui::IsKeyPressed(ImGuiKey_LeftCtrl)
                    || ImGui::IsKeyPressed(ImGuiKey_RightCtrl)
                    || ImGui::IsKeyDown(ImGuiKey_LeftCtrl)
                    || ImGui::IsKeyDown(ImGuiKey_RightCtrl);
        bool is_alt = ImGui::IsKeyPressed(ImGuiKey_LeftAlt)
                    || ImGui::IsKeyPressed(ImGuiKey_RightAlt)
                    || ImGui::IsKeyDown(ImGuiKey_LeftAlt)
                    || ImGui::IsKeyDown(ImGuiKey_RightAlt);
        bool is_shift = ImGui::IsKeyPressed(ImGuiKey_LeftShift)
                    || ImGui::IsKeyPressed(ImGuiKey_RightShift)
                    || ImGui::IsKeyDown(ImGuiKey_LeftShift)
                    || ImGui::IsKeyDown(ImGuiKey_RightShift);

        auto insert_char = [&](unsigned int c) {
            char_t elem;
            bool ascii = false;
            if (is_alt) {
                if (is_shift) {
                    if (greek_alternative[c].with_alt_shift1)
                        elem = gchar(greek_alternative[c].with_alt_shift1);
                    else  {
                        ascii = true;
                        c = toupper(c);
                    }
                }
                else {
                    if (greek_alternative[c].with_alt)
                        elem = gchar(greek_alternative[c].with_alt);
                    else
                        ascii = true;
                }
            }
            else
                ascii = true;
            if (ascii) {
                elem = gascii(c);
                if (elem.fnum == FONT_MATH)
                    elem.fnum = FONT_NORMAL;
            }
            elem.flvl;
            if (is_italic && elem.fnum == FONT_NORMAL)
                elem.fnum = FONT_ITALIC;
            if (is_bold && elem.fnum == FONT_NORMAL)
                elem.fnum = FONT_BOLD;

            chars.insert(chars.begin() + cursor_pos, elem);
            cursor_pos++;
        };

        auto insert_char_spec = [this](char_t elem) {
            chars.insert(chars.begin() + cursor_pos, elem);
            cursor_pos++;
        };

        struct key_t {
            ImGuiKey imgui_key;
            uint8_t ascii;

            bool toggled = false;
            uint64_t toggle_ms = 0;
            uint64_t toggle_ms_skip = 0;
        };

        static key_t keys[] = {
            {ImGuiKey_A, 'a'}, {ImGuiKey_B, 'b'}, {ImGuiKey_C, 'c'}, {ImGuiKey_D, 'd'},
            {ImGuiKey_E, 'e'}, {ImGuiKey_F, 'f'}, {ImGuiKey_G, 'g'}, {ImGuiKey_H, 'h'},
            {ImGuiKey_I, 'i'}, {ImGuiKey_J, 'j'}, {ImGuiKey_K, 'k'}, {ImGuiKey_L, 'l'},
            {ImGuiKey_M, 'm'}, {ImGuiKey_N, 'n'}, {ImGuiKey_O, 'o'}, {ImGuiKey_P, 'p'},
            {ImGuiKey_Q, 'q'}, {ImGuiKey_R, 'r'}, {ImGuiKey_S, 's'}, {ImGuiKey_T, 't'},
            {ImGuiKey_U, 'u'}, {ImGuiKey_V, 'v'}, {ImGuiKey_W, 'w'}, {ImGuiKey_X, 'x'},
            {ImGuiKey_Y, 'y'}, {ImGuiKey_Z, 'z'}
        };

        uint64_t time_now_ms = get_time_ms();
        for (auto &key: keys) {
            bool is_key = ImGui::IsKeyPressed(key.imgui_key) || ImGui::IsKeyDown(key.imgui_key);
            if (is_key && is_alt && !key.toggled) {
                key.toggled = true;
                key.toggle_ms = time_now_ms + 1000 - key.toggle_ms_skip;
                insert_char(key.ascii);
            }
            if (key.toggled && !is_key) {
                key.toggled = false;
            }
            else if (key.toggled && (key.toggle_ms < time_now_ms)) {
                key.toggled = false;
                key.toggle_ms_skip = 990;
            }
            if (!is_key)
                key.toggle_ms_skip = 0;                
        }

        if (io->InputQueueCharacters.Size > 0) {
            for (int n = 0; n < io->InputQueueCharacters.Size; n++) {
                unsigned int c = (unsigned int)io->InputQueueCharacters[n];
                insert_char(c);
            }

            // Consume characters
            io->InputQueueCharacters.resize(0);
        }

        if (ImGui::IsKeyPressed(ImGuiKey_Backspace)) {
            if (cursor_pos > 0) {
                cursor_pos--;
                chars.erase(chars.begin() + cursor_pos);
            }
        }
        
        if (ImGui::IsKeyPressed(ImGuiKey_RightArrow)) {
            auto cursor_on_whitespace = [&] {
                return cursor_pos != chars.size() && isspace(chars[cursor_pos].acod);
            };
            auto cursor_on_alpha = [&] {
                return cursor_pos != chars.size() && isalnum(chars[cursor_pos].acod);
            };
            auto move_right = [&]{
                if (cursor_pos < chars.size())
                    cursor_pos++;
            };
            if (!is_ctrl) {
                move_right();
            }
            else {
                while (cursor_on_whitespace() && cursor_pos != chars.size())
                    move_right();
                do
                    move_right();
                while (cursor_on_alpha());
            }
        }
        if (ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) {
            auto cursor_on_whitespace = [&] {
                return cursor_pos != 0 && isspace(chars[cursor_pos-1].acod);
            };
            auto cursor_on_alpha = [&] {
                return cursor_pos != 0 && isalnum(chars[cursor_pos-1].acod);
            };
            auto move_left = [&]{
                if (cursor_pos > 0)
                    cursor_pos--;
            };
            if (!is_ctrl) {
                move_left();
            }
            else {
                while (cursor_on_whitespace())
                    move_left();
                do
                    move_left();
                while (cursor_on_alpha() && cursor_pos > 0);
            }
        }
        if (ImGui::IsKeyPressed(ImGuiKey_UpArrow)) {
            int dist = 0;
            while (cursor_pos != 0 && chars[cursor_pos-1].acod != '\n') {
                cursor_pos--;
                dist++;
            }
            if (cursor_pos != 0 && chars[cursor_pos-1].acod == '\n')
                cursor_pos--;
            int maxdist = 0;
            while (cursor_pos != 0 && chars[cursor_pos-1].acod != '\n') {
                cursor_pos--;
                maxdist++;
            }
            if (dist > maxdist)
                dist = maxdist;
            cursor_pos += dist;
        }
        if (ImGui::IsKeyPressed(ImGuiKey_DownArrow)) {
            int dist = 0;
            while (cursor_pos != 0 && chars[cursor_pos-1].acod != '\n') {
                cursor_pos--;
                dist++;
            }
            while (cursor_pos != chars.size() && chars[cursor_pos].acod != '\n') {
                cursor_pos++;
            }
            if (cursor_pos != chars.size())
                cursor_pos++;
            while (dist && cursor_pos != chars.size() && chars[cursor_pos].acod != '\n') {
                cursor_pos++;
                dist--;
            }
        }
        if (is_ctrl && ImGui::IsKeyPressed(ImGuiKey_B)) {
            if (is_bold)
                is_bold = false;
            else
                is_bold = true;
            is_italic = false;
        }
        if (is_ctrl && ImGui::IsKeyPressed(ImGuiKey_I)) {
            if (is_italic)
                is_italic = false;
            else
                is_italic = true;
            is_bold = false;
        }
        if (is_ctrl && ImGui::IsKeyPressed(ImGuiKey_Minus)) {
            switch (flvl) {
                case FONT_LVL_SUB0: flvl = FONT_LVL_SUB1; break;
                case FONT_LVL_SUB1: flvl = FONT_LVL_SUB2; break;
                case FONT_LVL_SUB2: flvl = FONT_LVL_SUB3; break;
                case FONT_LVL_SUB3: flvl = FONT_LVL_SUB4; break;
            }
        }
        if (is_ctrl && ImGui::IsKeyPressed(ImGuiKey_Equal)) {
            switch (flvl) {
                case FONT_LVL_SUB1: flvl = FONT_LVL_SUB0; break;
                case FONT_LVL_SUB2: flvl = FONT_LVL_SUB1; break;
                case FONT_LVL_SUB3: flvl = FONT_LVL_SUB2; break;
                case FONT_LVL_SUB4: flvl = FONT_LVL_SUB3; break;
            }
        }
        if (is_ctrl && ImGui::IsKeyPressed(ImGuiKey_S)) {
            DBG("ascii_text: %s", ascii().c_str());
        }
        if (ImGui::IsKeyPressed(ImGuiKey_Enter) || ImGui::IsKeyPressed(ImGuiKey_KeypadEnter)) {
            insert_char_spec(char_t{.acod='\n', .flvl=FONT_LVL_SPECIAL});
        }
        if (ImGui::IsKeyPressed(ImGuiKey_Tab)) {
            for (int i = 0; i < 4; i++) {
                insert_char(' ');
            }
        }
    }

    std::pair<float, float> draw_area(float width_limit, float height_limit) override {
        init_line_vars();
        ImVec2 off = ImVec2(0, 0);
        this->line_count = 0;
        this->max_width = 0;
        for (int i = 0; i < chars.size(); i++) {
            if (chars[i].flvl == FONT_LVL_SPECIAL) {
                off.x = 0;
                off.y += comments_line_height[flvl];
                this->line_count++;
            }
            else if (off.x + char_get_sz(chars[i]).adv > width_limit) {
                off.x = 0;
                off.y += comments_line_height[flvl];
                this->line_count++;
            }
            else {
                off.x += char_get_sz(chars[i]).adv;
                this->max_width = std::max(this->max_width, off.x);
            }
        }

        return {this->max_width, off.y + comments_line_height[flvl]};
    }

    void draw(ImVec2 pos, float width_limit, float height_limit) override {
        ImVec2 off = ImVec2(0, 0);
        ImVec2 blinker_pos = pos + off + ImVec2(2, comments_line_height[flvl]);
        for (int i = 0; i < chars.size(); i++) {
            if (chars[i].flvl == FONT_LVL_SPECIAL) {
                off.x = 0;
                off.y += comments_line_height[flvl];
            }
            else if (off.x + char_get_sz(chars[i]).adv > width_limit) {
                off.x = 0;
                off.y += comments_line_height[flvl];
            }
            else {
                chars[i].flvl = flvl;
                char_draw(pos + off - ImVec2(0, comments_pos_increment[flvl]), chars[i],
                        0xff'eeeeee);
                off.x += char_get_sz(chars[i]).adv;
            }
            if (i+1 == cursor_pos)
                blinker_pos = pos + off + ImVec2(2, comments_line_height[flvl]);
        }
        draw_blinker(blinker_pos, comments_line_height[flvl]);
    }

    inline void draw_blinker(ImVec2 pos, float sz) {
        ImDrawList* draw_list = ImGui::GetWindowDrawList();
        draw_list->AddLine(pos, pos + ImVec2(0, -sz), 0xff'00ffff, 2);
    }

    std::string ascii() {
        std::string str(chars.size(), '?');

        for (int i = 0; i < chars.size(); i++)
            str[i] = chars[i].acod ? chars[i].acod : '?';
        return str;
    }

private:
    inline void init_line_vars() {
        for (int i = 0; i < FONT_LVL_CNT; i++) {
            auto G = gascii('G');
            auto g = gascii('g');
            G.flvl = i;
            g.flvl = i;
            auto [G1, G2] = char_get_draw_box(G, ImVec2(0, 0));
            auto [g1, g2] = char_get_draw_box(g, ImVec2(0, 0));
            comments_line_height[i] = g2.y - G1.y;
            comments_pos_increment[i] = G1.y;
        }
    }
};


#endif
