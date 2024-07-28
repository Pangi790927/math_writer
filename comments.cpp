#define IMGUI_DEFINE_MATH_OPERATORS

#include "comments.h"
#include "fonts.h"
#include "debug.h"

struct comment_text_t {
    std::vector<symbol_t *> chars;    
};

symbol_t comment_normal[128] = {};
symbol_t comment_italic[128] = {};
symbol_t comment_bold[128] = {};
symbol_t comment_special[128] = {};

int comments_init() {
    for (uint8_t code = 0x20; code < 0x7F; code++) {
        font_sub_e font_sub = FONT_NORMAL;
        font_lvl_e font_lvl = FONT_LVL_SUB2;

        uint8_t _code = code;
        if (code == '<' ) { _code = 0x3C; font_sub = FONT_MATH; }
        if (code == '>' ) { _code = 0x3E; font_sub = FONT_MATH; }
        if (code == '\\') { _code = 0x6E; font_sub = FONT_SYMBOLS; }
        if (code == '{' ) { _code = 0x66; font_sub = FONT_SYMBOLS; }
        if (code == '}' ) { _code = 0x67; font_sub = FONT_SYMBOLS; }
        if (code == '_' ) { _code = 0x5F; font_sub = FONT_MONO; }
        if (code == '|' ) { _code = 0x6A; font_sub = FONT_SYMBOLS; }
        if (code == '`' ) { _code = 0xB5; font_sub = FONT_NORMAL; }

        comment_normal[code] = symbol_t{ .code = _code, .font_lvl = font_lvl, .font_sub = font_sub };
        comment_bold[code] = comment_normal[code];
        if (comment_bold[code].font_sub == FONT_NORMAL)
            comment_bold[code].font_sub = FONT_BOLD;
        comment_italic[code] = comment_normal[code];
        if (comment_italic[code].font_sub == FONT_NORMAL)
            comment_italic[code].font_sub = FONT_ITALIC;
    }
    comment_special['\n'] = symbol_t{ .code = '\n', .font_lvl = FONT_LVL_SPECIAL };
    return 0;
}

static void draw_blinker(ImVec2 pos, float sz) {
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    draw_list->AddLine(ImVec2(pos), pos + ImVec2(0, -sz), 0xff'00ffff, 1);
}

int comment_text() {
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
    
    ImVec2 _pos = ImVec2(0, 30);
    ImVec2 pos = _pos;
    ImVec2 win_end = ImGui::GetContentRegionMax();
    float min_space = symbol_get_font(comment_bold['a'])->FontSize;
    for (auto psym : text.chars) {
        if (psym->font_lvl == FONT_LVL_SPECIAL)
            continue;
        min_space = std::max(min_space, symbol_get_font(*psym)->FontSize);
    }
    pos.y += min_space;

    ImVec2 blinker_pos = pos + ImVec2(2, 0);
    for (int i = 0; i < text.chars.size(); i++) {
        auto psym = text.chars[i];
        if (psym->font_lvl == FONT_LVL_SPECIAL) {
            pos.x = _pos.x;
            pos.y += min_space;
        }
        else if (pos.x + symbol_get_sz(*psym).adv > win_end.x) {
            pos.x = _pos.x;
            pos.y += min_space;
        }
        else {
            symbol_draw(ImVec2(pos.x, pos.y), *psym);
            pos.x += symbol_get_sz(*psym).adv;
        }
        if (i+1 == cursor_pos)
            blinker_pos = pos + ImVec2(2, 0);
    }
    draw_blinker(blinker_pos, min_space);
    return 0;
}
