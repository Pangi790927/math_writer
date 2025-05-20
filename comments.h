#ifndef COMMENTS_H
#define COMMENTS_H

#include "chars.h"
#include "debug.h"

inline int comments_init();
inline int comment_text();

/* IMPLEMENTATION
 * =================================================================================================
 */

struct comment_text_t {
    std::vector<char_t *> chars;
};

inline char_t comment_normal[128] = {};
inline char_t comment_italic[128] = {};
inline char_t comment_bold[128] = {};
inline char_t comment_special[128] = {};

inline int comments_init() {
    for (uint8_t code = 0x20; code < 0x7F; code++) {
        char_font_num_e fnum = FONT_NORMAL;
        char_font_lvl_e flvl = FONT_LVL_SUB2;

        uint8_t _fcod = code;
        if (code == '<' ) { _fcod = 0x3C; fnum = FONT_MATH; }
        if (code == '>' ) { _fcod = 0x3E; fnum = FONT_MATH; }
        if (code == '\\') { _fcod = 0x6E; fnum = FONT_SYMBOLS; }
        if (code == '{' ) { _fcod = 0x66; fnum = FONT_SYMBOLS; }
        if (code == '}' ) { _fcod = 0x67; fnum = FONT_SYMBOLS; }
        if (code == '_' ) { _fcod = 0x5F; fnum = FONT_MONO; }
        if (code == '|' ) { _fcod = 0x6A; fnum = FONT_SYMBOLS; }
        if (code == '`' ) { _fcod = 0xB5; fnum = FONT_NORMAL; }

        comment_normal[code] = char_t{ .fcod = _fcod, .fnum = fnum, .flvl = flvl };
        comment_bold[code] = comment_normal[code];
        if (comment_bold[code].fnum == FONT_NORMAL)
            comment_bold[code].fnum = FONT_BOLD;
        comment_italic[code] = comment_normal[code];
        if (comment_italic[code].fnum == FONT_NORMAL)
            comment_italic[code].fnum = FONT_ITALIC;
    }
    comment_special['\n'] = char_t{ .fcod = '\n', .flvl = FONT_LVL_SPECIAL };
    return 0;
}

inline void draw_blinker(ImVec2 pos, float sz) {
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    draw_list->AddLine(pos, pos + ImVec2(0, -sz), 0xff'00ffff, 2);
}

inline int comment_text() {
    static comment_text_t text;
    static int cursor_pos = 0;
    static std::string ascii_text;
    static bool is_italic = false;
    static bool is_bold = false;

    auto get_charset = [&]() {
        if (is_italic)
            return comment_italic;
        if (is_bold)
            return comment_bold;
        return comment_normal;
    };
    /* TODO: add some indicators for italic, bold, etc */
    auto insert_char = [&](unsigned int c, auto charset) {
        text.chars.insert(text.chars.begin() + cursor_pos, &charset[c]);
        ascii_text += (char)c;
        cursor_pos++;
    };

    auto *io = &ImGui::GetIO();
    if (io->InputQueueCharacters.Size > 0) {
        for (int n = 0; n < io->InputQueueCharacters.Size; n++) {
            unsigned int c = (unsigned int)io->InputQueueCharacters[n];
            insert_char(c, get_charset());
        }

        // Consume characters
        io->InputQueueCharacters.resize(0);
    }

    if (ImGui::IsKeyPressed(ImGuiKey_Backspace)) {
        if (cursor_pos > 0) {
            cursor_pos--;
            text.chars.erase(text.chars.begin() + cursor_pos);
        }
    }
    bool is_ctrl = ImGui::IsKeyPressed(ImGuiKey_LeftCtrl)
                || ImGui::IsKeyPressed(ImGuiKey_RightCtrl)
                || ImGui::IsKeyDown(ImGuiKey_LeftCtrl)
                || ImGui::IsKeyDown(ImGuiKey_RightCtrl);
    if (ImGui::IsKeyPressed(ImGuiKey_RightArrow)) {
        auto cursor_on_whitespace = [&] {
            return cursor_pos != text.chars.size() && isspace(text.chars[cursor_pos]->code);
        };
        auto cursor_on_alpha = [&] {
            return cursor_pos != text.chars.size() && isalnum(text.chars[cursor_pos]->code);
        };
        auto move_right = [&]{
            if (cursor_pos < text.chars.size())
                cursor_pos++;
        };
        if (!is_ctrl) {
            move_right();
        }
        else {
            while (cursor_on_whitespace() && cursor_pos != text.chars.size())
                move_right();
            do
                move_right();
            while (cursor_on_alpha());
        }
    }
    if (ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) {
        auto cursor_on_whitespace = [&] {
            return cursor_pos != 0 && isspace(text.chars[cursor_pos-1]->code);
        };
        auto cursor_on_alpha = [&] {
            return cursor_pos != 0 && isalnum(text.chars[cursor_pos-1]->code);
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
        while (cursor_pos != 0 && text.chars[cursor_pos-1]->code != '\n') {
            cursor_pos--;
            dist++;
        }
        if (cursor_pos != 0 && text.chars[cursor_pos-1]->code == '\n')
            cursor_pos--;
        int maxdist = 0;
        while (cursor_pos != 0 && text.chars[cursor_pos-1]->code != '\n') {
            cursor_pos--;
            maxdist++;
        }
        if (dist > maxdist)
            dist = maxdist;
        cursor_pos += dist;
    }
    if (ImGui::IsKeyPressed(ImGuiKey_DownArrow)) {
        int dist = 0;
        while (cursor_pos != 0 && text.chars[cursor_pos-1]->code != '\n') {
            cursor_pos--;
            dist++;
        }
        while (cursor_pos != text.chars.size() && text.chars[cursor_pos]->code != '\n') {
            cursor_pos++;
        }
        if (cursor_pos != text.chars.size())
            cursor_pos++;
        while (dist && cursor_pos != text.chars.size() && text.chars[cursor_pos]->code != '\n') {
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
    if (is_ctrl && ImGui::IsKeyPressed(ImGuiKey_S)) {
        DBG("ascii_text: %s", ascii_text.c_str());
    }
    if (ImGui::IsKeyPressed(ImGuiKey_Enter) || ImGui::IsKeyPressed(ImGuiKey_KeypadEnter)) {
        insert_char('\n', comment_special);
    }
    if (ImGui::IsKeyPressed(ImGuiKey_Tab)) {
        for (int i = 0; i < 4; i++) {
            insert_char(' ', get_charset());
        }
    }
    
    ImVec2 _pos = ImVec2(10, 30);
    ImVec2 pos = _pos;
    ImVec2 win_end = ImGui::GetContentRegionMax();


    auto g = gchar('g');
    auto G = gchar('G');
    g.flvl = FONT_LVL_SUB2;
    G.flvl = FONT_LVL_SUB2;
    auto [a1, b1] = char_get_draw_box(ImVec2(0, 0), G);
    auto [a2, b2] = char_get_draw_box(ImVec2(0, 0), g);
    float min_space = b2.y - a1.y;

    ImVec2 blinker_pos = pos + ImVec2(2, 0);
    for (int i = 0; i < text.chars.size(); i++) {
        auto psym = text.chars[i];
        if (psym->flvl == FONT_LVL_SPECIAL) {
            pos.x = _pos.x;
            pos.y += min_space;
        }
        else if (pos.x + char_get_sz(*psym).adv > win_end.x) {
            pos.x = _pos.x;
            pos.y += min_space;
        }
        else {
            char_draw(pos - ImVec2(0, b1.y), *psym);
            pos.x += char_get_sz(*psym).adv;
        }
        if (i+1 == cursor_pos)
            blinker_pos = pos + ImVec2(2, 0);
    }
    draw_blinker(blinker_pos, min_space);
    return 0;
}

#endif
