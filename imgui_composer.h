#ifndef IMGUI_COMPOSER_H
#define IMGUI_COMPOSER_H

#include "virt_composer.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include "imgui_internal.h"

namespace virt_composer {

extern inline std::unordered_map<std::string, ImGuiKey> imgui_key_from_str;
extern inline std::unordered_map<std::string, ImGuiMouseButton_> imgui_mousebtn_from_str;

template <> inline ImGuiKey get_enum_val<ImGuiKey>(fkyaml::node &n);
template <> inline ImGuiMouseButton_ get_enum_val<ImGuiMouseButton_>(fkyaml::node &n);

} /* namespace virt_composer */

namespace imgui_composer {

namespace vc = virt_composer;
namespace imgc = imgui_composer;

inline std::vector<uint32_t> input_queue_chars() {
    auto &io = ImGui::GetIO();
    return std::vector<uint32_t>(io.InputQueueCharacters.begin(), io.InputQueueCharacters.end());
}

inline ImVec2 get_display_size() {
    return ImGui::GetIO().DisplaySize;
}

/*! This frame's vertical mouse wheel delta (positive = away from the user, the usual "scroll up"
 * direction) - not previously exposed; debug_input_pipe.cpp could already inject a wheel event
 * (AddMouseWheelEvent), but nothing could read the resulting io.MouseWheel back out from Lua. */
inline float get_mouse_wheel() {
    return ImGui::GetIO().MouseWheel;
}

/*! Returns the current window's draw list, or nullptr if this window's items are being skipped
 * (mirrors the guard char_draw_composer::fontset_t::char_draw already uses). All ImGui_Add*
 * drawing functions below go through this. */
inline ImDrawList *draw_list() {
    ImGuiWindow *window = ImGui::GetCurrentWindow();
    if (window->SkipItems)
        return nullptr;
    return ImGui::GetWindowDrawList();
}

inline void add_line(ImVec2 p1, ImVec2 p2, uint32_t col, float thickness) {
    if (auto *dl = draw_list())
        dl->AddLine(p1, p2, col, thickness);
}

inline void add_rect(ImVec2 p_min, ImVec2 p_max, uint32_t col, float rounding, float thickness) {
    if (auto *dl = draw_list())
        dl->AddRect(p_min, p_max, col, rounding, 0, thickness);
}

inline void add_rect_filled(ImVec2 p_min, ImVec2 p_max, uint32_t col, float rounding) {
    if (auto *dl = draw_list())
        dl->AddRectFilled(p_min, p_max, col, rounding, 0);
}

inline void add_circle(ImVec2 center, float radius, uint32_t col, float thickness) {
    if (auto *dl = draw_list())
        dl->AddCircle(center, radius, col, 0, thickness);
}

inline void add_circle_filled(ImVec2 center, float radius, uint32_t col) {
    if (auto *dl = draw_list())
        dl->AddCircleFilled(center, radius, col, 0);
}

inline void add_triangle(ImVec2 p1, ImVec2 p2, ImVec2 p3, uint32_t col, float thickness) {
    if (auto *dl = draw_list())
        dl->AddTriangle(p1, p2, p3, col, thickness);
}

inline void add_triangle_filled(ImVec2 p1, ImVec2 p2, ImVec2 p3, uint32_t col) {
    if (auto *dl = draw_list())
        dl->AddTriangleFilled(p1, p2, p3, col);
}

/*! Not requested, but the same shape as triangle/rect and just as cheap to expose - a 4-point
 * poly. Straightforward to drop if unwanted. */
inline void add_quad(ImVec2 p1, ImVec2 p2, ImVec2 p3, ImVec2 p4, uint32_t col, float thickness) {
    if (auto *dl = draw_list())
        dl->AddQuad(p1, p2, p3, p4, col, thickness);
}

inline void add_quad_filled(ImVec2 p1, ImVec2 p2, ImVec2 p3, ImVec2 p4, uint32_t col) {
    if (auto *dl = draw_list())
        dl->AddQuadFilled(p1, p2, p3, p4, col);
}

/*! Also not requested: raw ImGui-font text (not the char.lua glyph catalog / fontset_t). Handy
 * for quick debug/UI labels without going through char_draw. Straightforward to drop if unwanted. */
inline void add_text(ImVec2 pos, uint32_t col, const char *text) {
    if (auto *dl = draw_list())
        dl->AddText(pos, col, text);
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> imgui_tab_funcs = {
        {"ImGui_IsKeyDown", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiKey)>(ImGui::IsKeyDown),
               /* PARAMS:*/ vc::bm_t<ImGuiKey>
        >},
        {"ImGui_IsKeyPressed", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiKey, bool)>(ImGui::IsKeyPressed),
               /* PARAMS:*/ vc::bm_t<ImGuiKey>,
                            bool
        >},
        {"ImGui_IsKeyReleased", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiKey)>(ImGui::IsKeyReleased),
               /* PARAMS:*/ vc::bm_t<ImGuiKey>
        >},
        {"ImGui_IsKeyChordPressed", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiKeyChord)>(ImGui::IsKeyChordPressed),
               /* PARAMS:*/ vc::bm_t<ImGuiKey>
        >},
        {"ImGui_input_queue_chars", vc::luaw_function_wrapper<
               /* FN:    */ input_queue_chars
        >},

        /* Mouse -------------------------------------------------------------------------------- */
        /* NOTE: IsMouseDown/Clicked/Released/DoubleClicked are overloaded once
         * imgui_internal.h is visible (owner-aware variants) - disambiguate to the public,
         * non-owner-aware overload, same as ImGui_IsKeyDown/Pressed/Released above. */
        {"ImGui_IsMouseDown", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiMouseButton)>(ImGui::IsMouseDown),
               /* PARAMS:*/ vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_IsMouseClicked", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiMouseButton, bool)>(ImGui::IsMouseClicked),
               /* PARAMS:*/ vc::bm_t<ImGuiMouseButton_>,
                            bool
        >},
        {"ImGui_IsMouseReleased", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiMouseButton)>(ImGui::IsMouseReleased),
               /* PARAMS:*/ vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_IsMouseDoubleClicked", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiMouseButton)>(ImGui::IsMouseDoubleClicked),
               /* PARAMS:*/ vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_IsMouseReleasedWithDelay", vc::luaw_function_wrapper<
               ImGui::IsMouseReleasedWithDelay, vc::bm_t<ImGuiMouseButton_>, float
        >},
        {"ImGui_GetMouseClickedCount", vc::luaw_function_wrapper<
               ImGui::GetMouseClickedCount, vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_IsMouseHoveringRect", vc::luaw_function_wrapper<
               ImGui::IsMouseHoveringRect, ImVec2, ImVec2, bool
        >},
        {"ImGui_GetMousePos", vc::luaw_function_wrapper<
               ImGui::GetMousePos
        >},
        {"ImGui_GetDisplaySize", vc::luaw_function_wrapper<
               get_display_size
        >},
        {"ImGui_GetMouseWheel", vc::luaw_function_wrapper<
               get_mouse_wheel
        >},
        {"ImGui_IsMouseDragging", vc::luaw_function_wrapper<
               ImGui::IsMouseDragging, vc::bm_t<ImGuiMouseButton_>, float
        >},
        {"ImGui_GetMouseDragDelta", vc::luaw_function_wrapper<
               ImGui::GetMouseDragDelta, vc::bm_t<ImGuiMouseButton_>, float
        >},
        {"ImGui_ResetMouseDragDelta", vc::luaw_function_wrapper<
               ImGui::ResetMouseDragDelta, vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_GetClipboardText", vc::luaw_function_wrapper<
               ImGui::GetClipboardText
        >},
        {"ImGui_SetClipboardText", vc::luaw_function_wrapper<
               ImGui::SetClipboardText, const char *
        >},

        /* Drawing (operate on the current window's draw list) ---------------------------------- */
        {"ImGui_AddLine", vc::luaw_function_wrapper<
               add_line, ImVec2, ImVec2, uint32_t, float
        >},
        {"ImGui_AddRect", vc::luaw_function_wrapper<
               add_rect, ImVec2, ImVec2, uint32_t, float, float
        >},
        {"ImGui_AddRectFilled", vc::luaw_function_wrapper<
               add_rect_filled, ImVec2, ImVec2, uint32_t, float
        >},
        {"ImGui_AddCircle", vc::luaw_function_wrapper<
               add_circle, ImVec2, float, uint32_t, float
        >},
        {"ImGui_AddCircleFilled", vc::luaw_function_wrapper<
               add_circle_filled, ImVec2, float, uint32_t
        >},
        {"ImGui_AddTriangle", vc::luaw_function_wrapper<
               add_triangle, ImVec2, ImVec2, ImVec2, uint32_t, float
        >},
        {"ImGui_AddTriangleFilled", vc::luaw_function_wrapper<
               add_triangle_filled, ImVec2, ImVec2, ImVec2, uint32_t
        >},
        {"ImGui_AddQuad", vc::luaw_function_wrapper<
               add_quad, ImVec2, ImVec2, ImVec2, ImVec2, uint32_t, float
        >},
        {"ImGui_AddQuadFilled", vc::luaw_function_wrapper<
               add_quad_filled, ImVec2, ImVec2, ImVec2, ImVec2, uint32_t
        >},
        {"ImGui_AddText", vc::luaw_function_wrapper<
               add_text, ImVec2, uint32_t, const char *
        >},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, imgui_tab_funcs));

    vc::add_lua_flag_mapping(vs, vc::imgui_key_from_str);
    vc::add_lua_flag_mapping(vs, vc::imgui_mousebtn_from_str);

    return vc::VC_ERROR_OK;
}

} /* namespace imgui_composer */

namespace virt_composer {

inline std::unordered_map<std::string, ImGuiKey> imgui_key_from_str = {
    { "ImGuiKey_None", ImGuiKey_None },
    { "ImGuiKey_NamedKey_BEGIN", ImGuiKey_NamedKey_BEGIN },
    { "ImGuiKey_Tab", ImGuiKey_Tab },
    { "ImGuiKey_LeftArrow", ImGuiKey_LeftArrow },
    { "ImGuiKey_RightArrow", ImGuiKey_RightArrow },
    { "ImGuiKey_UpArrow", ImGuiKey_UpArrow },
    { "ImGuiKey_DownArrow", ImGuiKey_DownArrow },
    { "ImGuiKey_PageUp", ImGuiKey_PageUp },
    { "ImGuiKey_PageDown", ImGuiKey_PageDown },
    { "ImGuiKey_Home", ImGuiKey_Home },
    { "ImGuiKey_End", ImGuiKey_End },
    { "ImGuiKey_Insert", ImGuiKey_Insert },
    { "ImGuiKey_Delete", ImGuiKey_Delete },
    { "ImGuiKey_Backspace", ImGuiKey_Backspace },
    { "ImGuiKey_Space", ImGuiKey_Space },
    { "ImGuiKey_Enter", ImGuiKey_Enter },
    { "ImGuiKey_Escape", ImGuiKey_Escape },
    { "ImGuiKey_LeftCtrl", ImGuiKey_LeftCtrl },
    { "ImGuiKey_LeftShift", ImGuiKey_LeftShift },
    { "ImGuiKey_LeftAlt", ImGuiKey_LeftAlt },
    { "ImGuiKey_LeftSuper", ImGuiKey_LeftSuper },
    { "ImGuiKey_RightCtrl", ImGuiKey_RightCtrl },
    { "ImGuiKey_RightShift", ImGuiKey_RightShift },
    { "ImGuiKey_RightAlt", ImGuiKey_RightAlt },
    { "ImGuiKey_RightSuper", ImGuiKey_RightSuper },
    { "ImGuiKey_Menu", ImGuiKey_Menu },
    { "ImGuiKey_0", ImGuiKey_0 },
    { "ImGuiKey_1", ImGuiKey_1 },
    { "ImGuiKey_2", ImGuiKey_2 },
    { "ImGuiKey_3", ImGuiKey_3 },
    { "ImGuiKey_4", ImGuiKey_4 },
    { "ImGuiKey_5", ImGuiKey_5 },
    { "ImGuiKey_6", ImGuiKey_6 },
    { "ImGuiKey_7", ImGuiKey_7 },
    { "ImGuiKey_8", ImGuiKey_8 },
    { "ImGuiKey_9", ImGuiKey_9 },
    { "ImGuiKey_A", ImGuiKey_A },
    { "ImGuiKey_B", ImGuiKey_B },
    { "ImGuiKey_C", ImGuiKey_C },
    { "ImGuiKey_D", ImGuiKey_D },
    { "ImGuiKey_E", ImGuiKey_E },
    { "ImGuiKey_F", ImGuiKey_F },
    { "ImGuiKey_G", ImGuiKey_G },
    { "ImGuiKey_H", ImGuiKey_H },
    { "ImGuiKey_I", ImGuiKey_I },
    { "ImGuiKey_J", ImGuiKey_J },
    { "ImGuiKey_K", ImGuiKey_K },
    { "ImGuiKey_L", ImGuiKey_L },
    { "ImGuiKey_M", ImGuiKey_M },
    { "ImGuiKey_N", ImGuiKey_N },
    { "ImGuiKey_O", ImGuiKey_O },
    { "ImGuiKey_P", ImGuiKey_P },
    { "ImGuiKey_Q", ImGuiKey_Q },
    { "ImGuiKey_R", ImGuiKey_R },
    { "ImGuiKey_S", ImGuiKey_S },
    { "ImGuiKey_T", ImGuiKey_T },
    { "ImGuiKey_U", ImGuiKey_U },
    { "ImGuiKey_V", ImGuiKey_V },
    { "ImGuiKey_W", ImGuiKey_W },
    { "ImGuiKey_X", ImGuiKey_X },
    { "ImGuiKey_Y", ImGuiKey_Y },
    { "ImGuiKey_Z", ImGuiKey_Z },
    { "ImGuiKey_F1", ImGuiKey_F1 },
    { "ImGuiKey_F2", ImGuiKey_F2 },
    { "ImGuiKey_F3", ImGuiKey_F3 },
    { "ImGuiKey_F4", ImGuiKey_F4 },
    { "ImGuiKey_F5", ImGuiKey_F5 },
    { "ImGuiKey_F6", ImGuiKey_F6 },
    { "ImGuiKey_F7", ImGuiKey_F7 },
    { "ImGuiKey_F8", ImGuiKey_F8 },
    { "ImGuiKey_F9", ImGuiKey_F9 },
    { "ImGuiKey_F10", ImGuiKey_F10 },
    { "ImGuiKey_F11", ImGuiKey_F11 },
    { "ImGuiKey_F12", ImGuiKey_F12 },
    { "ImGuiKey_F13", ImGuiKey_F13 },
    { "ImGuiKey_F14", ImGuiKey_F14 },
    { "ImGuiKey_F15", ImGuiKey_F15 },
    { "ImGuiKey_F16", ImGuiKey_F16 },
    { "ImGuiKey_F17", ImGuiKey_F17 },
    { "ImGuiKey_F18", ImGuiKey_F18 },
    { "ImGuiKey_F19", ImGuiKey_F19 },
    { "ImGuiKey_F20", ImGuiKey_F20 },
    { "ImGuiKey_F21", ImGuiKey_F21 },
    { "ImGuiKey_F22", ImGuiKey_F22 },
    { "ImGuiKey_F23", ImGuiKey_F23 },
    { "ImGuiKey_F24", ImGuiKey_F24 },
    { "ImGuiKey_Apostrophe", ImGuiKey_Apostrophe },
    { "ImGuiKey_Comma", ImGuiKey_Comma },
    { "ImGuiKey_Minus", ImGuiKey_Minus },
    { "ImGuiKey_Period", ImGuiKey_Period },
    { "ImGuiKey_Slash", ImGuiKey_Slash },
    { "ImGuiKey_Semicolon", ImGuiKey_Semicolon },
    { "ImGuiKey_Equal", ImGuiKey_Equal },
    { "ImGuiKey_LeftBracket", ImGuiKey_LeftBracket },
    { "ImGuiKey_Backslash", ImGuiKey_Backslash },
    { "ImGuiKey_RightBracket", ImGuiKey_RightBracket },
    { "ImGuiKey_GraveAccent", ImGuiKey_GraveAccent },
    { "ImGuiKey_CapsLock", ImGuiKey_CapsLock },
    { "ImGuiKey_ScrollLock", ImGuiKey_ScrollLock },
    { "ImGuiKey_NumLock", ImGuiKey_NumLock },
    { "ImGuiKey_PrintScreen", ImGuiKey_PrintScreen },
    { "ImGuiKey_Pause", ImGuiKey_Pause },
    { "ImGuiKey_Keypad0", ImGuiKey_Keypad0 },
    { "ImGuiKey_Keypad1", ImGuiKey_Keypad1 },
    { "ImGuiKey_Keypad2", ImGuiKey_Keypad2 },
    { "ImGuiKey_Keypad3", ImGuiKey_Keypad3 },
    { "ImGuiKey_Keypad4", ImGuiKey_Keypad4 },
    { "ImGuiKey_Keypad5", ImGuiKey_Keypad5 },
    { "ImGuiKey_Keypad6", ImGuiKey_Keypad6 },
    { "ImGuiKey_Keypad7", ImGuiKey_Keypad7 },
    { "ImGuiKey_Keypad8", ImGuiKey_Keypad8 },
    { "ImGuiKey_Keypad9", ImGuiKey_Keypad9 },
    { "ImGuiKey_KeypadDecimal", ImGuiKey_KeypadDecimal },
    { "ImGuiKey_KeypadDivide", ImGuiKey_KeypadDivide },
    { "ImGuiKey_KeypadMultiply", ImGuiKey_KeypadMultiply },
    { "ImGuiKey_KeypadSubtract", ImGuiKey_KeypadSubtract },
    { "ImGuiKey_KeypadAdd", ImGuiKey_KeypadAdd },
    { "ImGuiKey_KeypadEnter", ImGuiKey_KeypadEnter },
    { "ImGuiKey_KeypadEqual", ImGuiKey_KeypadEqual },
    { "ImGuiKey_AppBack", ImGuiKey_AppBack },
    { "ImGuiKey_AppForward", ImGuiKey_AppForward },
    { "ImGuiKey_Oem102", ImGuiKey_Oem102 },
    { "ImGuiKey_GamepadStart", ImGuiKey_GamepadStart },
    { "ImGuiKey_GamepadBack", ImGuiKey_GamepadBack },
    { "ImGuiKey_GamepadFaceLeft", ImGuiKey_GamepadFaceLeft },
    { "ImGuiKey_GamepadFaceRight", ImGuiKey_GamepadFaceRight },
    { "ImGuiKey_GamepadFaceUp", ImGuiKey_GamepadFaceUp },
    { "ImGuiKey_GamepadFaceDown", ImGuiKey_GamepadFaceDown },
    { "ImGuiKey_GamepadDpadLeft", ImGuiKey_GamepadDpadLeft },
    { "ImGuiKey_GamepadDpadRight", ImGuiKey_GamepadDpadRight },
    { "ImGuiKey_GamepadDpadUp", ImGuiKey_GamepadDpadUp },
    { "ImGuiKey_GamepadDpadDown", ImGuiKey_GamepadDpadDown },
    { "ImGuiKey_GamepadL1", ImGuiKey_GamepadL1 },
    { "ImGuiKey_GamepadR1", ImGuiKey_GamepadR1 },
    { "ImGuiKey_GamepadL2", ImGuiKey_GamepadL2 },
    { "ImGuiKey_GamepadR2", ImGuiKey_GamepadR2 },
    { "ImGuiKey_GamepadL3", ImGuiKey_GamepadL3 },
    { "ImGuiKey_GamepadR3", ImGuiKey_GamepadR3 },
    { "ImGuiKey_GamepadLStickLeft", ImGuiKey_GamepadLStickLeft },
    { "ImGuiKey_GamepadLStickRight", ImGuiKey_GamepadLStickRight },
    { "ImGuiKey_GamepadLStickUp", ImGuiKey_GamepadLStickUp },
    { "ImGuiKey_GamepadLStickDown", ImGuiKey_GamepadLStickDown },
    { "ImGuiKey_GamepadRStickLeft", ImGuiKey_GamepadRStickLeft },
    { "ImGuiKey_GamepadRStickRight", ImGuiKey_GamepadRStickRight },
    { "ImGuiKey_GamepadRStickUp", ImGuiKey_GamepadRStickUp },
    { "ImGuiKey_GamepadRStickDown", ImGuiKey_GamepadRStickDown },
    { "ImGuiKey_MouseLeft", ImGuiKey_MouseLeft },
    { "ImGuiKey_MouseRight", ImGuiKey_MouseRight },
    { "ImGuiKey_MouseMiddle", ImGuiKey_MouseMiddle },
    { "ImGuiKey_MouseX1", ImGuiKey_MouseX1 },
    { "ImGuiKey_MouseX2", ImGuiKey_MouseX2 },
    { "ImGuiKey_MouseWheelX", ImGuiKey_MouseWheelX },
    { "ImGuiKey_MouseWheelY", ImGuiKey_MouseWheelY },
    { "ImGuiKey_ReservedForModCtrl", ImGuiKey_ReservedForModCtrl },
    { "ImGuiKey_ReservedForModShift", ImGuiKey_ReservedForModShift },
    { "ImGuiKey_ReservedForModAlt", ImGuiKey_ReservedForModAlt },
    { "ImGuiKey_ReservedForModSuper", ImGuiKey_ReservedForModSuper },
    { "ImGuiKey_NamedKey_END", ImGuiKey_NamedKey_END },
    { "ImGuiKey_NamedKey_COUNT", ImGuiKey_NamedKey_COUNT },
    { "ImGuiMod_None", ImGuiMod_None },
    { "ImGuiMod_Ctrl", ImGuiMod_Ctrl },
    { "ImGuiMod_Shift", ImGuiMod_Shift },
    { "ImGuiMod_Alt", ImGuiMod_Alt },
    { "ImGuiMod_Super", ImGuiMod_Super },
    { "ImGuiMod_Mask_", ImGuiMod_Mask_ },
};

template <> inline ImGuiKey get_enum_val<ImGuiKey>(fkyaml::node &n) {
    return get_enum_val(n, imgui_key_from_str);
}

inline std::unordered_map<std::string, ImGuiMouseButton_> imgui_mousebtn_from_str = {
    { "ImGuiMouseButton_Left", ImGuiMouseButton_Left },
    { "ImGuiMouseButton_Right", ImGuiMouseButton_Right },
    { "ImGuiMouseButton_Middle", ImGuiMouseButton_Middle },
};

template <> inline ImGuiMouseButton_ get_enum_val<ImGuiMouseButton_>(fkyaml::node &n) {
    return get_enum_val(n, imgui_mousebtn_from_str);
}


} /* namespace virt_composer */

#endif
