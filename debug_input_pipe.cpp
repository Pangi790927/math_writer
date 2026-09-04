/*! DEBUG-ONLY, explicitly not for production use. See debug_input_pipe.h. */
#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS

#include "debug_input_pipe.h"

#include <atomic>
#include <thread>
#include <mutex>
#include <deque>
#include <sstream>
#include <string>
#include <vector>
#include <cstdlib>
#include <cstdio>
#include <cstdint>

#ifdef _WIN32
# ifndef WIN32_LEAN_AND_MEAN
#  define WIN32_LEAN_AND_MEAN
# endif
# include <winsock2.h>
# include <ws2tcpip.h>
# include <windows.h> /* hide_console(): HWND/GetConsoleWindow/ShowWindow */
# pragma comment(lib, "ws2_32.lib")
using socket_t = SOCKET;
static const socket_t INVALID_SOCK = INVALID_SOCKET;
# define CLOSESOCK closesocket
#else
# include <sys/socket.h>
# include <netinet/in.h>
# include <arpa/inet.h>
# include <unistd.h>
using socket_t = int;
static const socket_t INVALID_SOCK = -1;
# define CLOSESOCK close
#endif

/* imgui_composer.h's register_meta() uses ImVec2 as a Lua param/return type, whose virt_composer
interop specializations live in char_draw_composer.h - main.cpp always includes both together for
the same reason, this TU needs to too. Also pulls in imgui.h (ImGuiIO/AddXxxEvent) and
virt_composer::imgui_key_from_str (so "key_down ImGuiKey_A" etc. use the exact same key-name
table the Lua bindings already use). */
#include "char_draw_composer.h"
#include "imgui_composer.h"
#include "debug.h"

/* reveal_window(): the imgui_window global, glfwSetWindowPos/glfwShowWindow. */
#include "imgui_helpers.h"

#ifdef _WIN32
/* glfwGetWin32Window() - reveal_window() shows the window via the native Win32 API instead of
glfwShowWindow() so it can pass SW_SHOWNOACTIVATE: GLFW's own glfwShowWindow() always also
focuses the window (there's no GLFW-level equivalent of "show without activating"), which defeats
the entire point of showing it pre-positioned - the whole reason this module positions the window
before ever revealing it is so automated driving never steals the developer's focus (see this
file's own top comment / debug_input_pipe.h's doc comment). Must be included after glfw3.h
(pulled in transitively above via imgui_helpers.h) and after windows.h (included near the top of
this file). */
# define GLFW_EXPOSE_NATIVE_WIN32
# include <GLFW/glfw3native.h>
#endif

namespace debug_input_pipe {

namespace {

/*! Writes an uncompressed 24-bit BMP (top-to-bottom `rgb` pixel data, `w*h*3` bytes, row-major).
No external dependency (stb_image_write.h etc.) needed for a format this simple - BMP's only real
complication vs. writing raw bytes is that scanlines are bottom-to-top and each row is padded to a
multiple of 4 bytes, both handled below. Returns false on any I/O failure. */
bool write_bmp(const char *path, int w, int h, const unsigned char *rgb) {
    FILE *f = fopen(path, "wb");
    if (!f)
        return false;

    int row_sz = w * 3;
    int row_pad = (4 - (row_sz % 4)) % 4;
    int padded_row_sz = row_sz + row_pad;
    uint32_t pixel_data_sz = (uint32_t)(padded_row_sz * h);
    uint32_t file_sz = 14 + 40 + pixel_data_sz;

    unsigned char bmp_header[14] = {
        'B', 'M',
        (unsigned char)(file_sz), (unsigned char)(file_sz >> 8),
        (unsigned char)(file_sz >> 16), (unsigned char)(file_sz >> 24),
        0, 0, 0, 0,
        54, 0, 0, 0 /* pixel data offset */
    };
    unsigned char dib_header[40] = {0};
    *(uint32_t *)(dib_header + 0) = 40;
    *(int32_t  *)(dib_header + 4) = w;
    *(int32_t  *)(dib_header + 8) = h;
    *(uint16_t *)(dib_header + 12) = 1;
    *(uint16_t *)(dib_header + 14) = 24;
    *(uint32_t *)(dib_header + 20) = pixel_data_sz;

    fwrite(bmp_header, 1, sizeof(bmp_header), f);
    fwrite(dib_header, 1, sizeof(dib_header), f);

    unsigned char pad[3] = {0, 0, 0};
    /* BMP stores rows bottom-to-top; glReadPixels() already reads bottom-to-top too (GL's origin
    is bottom-left), so row 0 read from GL is already BMP's LAST row - write rows in the order
    they come in, no flip needed. Each pixel is RGB from GL but BMP wants BGR. */
    for (int row = 0; row < h; row++) {
        const unsigned char *src_row = rgb + (size_t)row * row_sz;
        for (int col = 0; col < w; col++) {
            unsigned char bgr[3] = {src_row[col * 3 + 2], src_row[col * 3 + 1], src_row[col * 3 + 0]};
            fwrite(bgr, 1, 3, f);
        }
        if (row_pad)
            fwrite(pad, 1, row_pad, f);
    }

    fclose(f);
    return true;
}

/*! Captures the current framebuffer (whatever was last drawn - call after a real frame has
rendered, e.g. from pump(), which runs before ImGui::NewFrame() for the frame AFTER the one that
drew what you want to see - see this file's own doc comment on pump()'s timing) via glReadPixels()
and writes it to `path` as a BMP. Works whether or not the window is actually visible/shown -
GLFW/OpenGL rendering to the window's own framebuffer never depended on the OS actually presenting
it on screen, only glfwSwapBuffers() needs to have run, which the main loop already does every
frame regardless of visibility - this is what makes VC_WINDOW_STAY_HIDDEN (see reveal_window())
useful for fully headless automated driving: never show the window at all, ever, and use this
command instead of a real screen capture. */
bool capture_screenshot(const char *path) {
    int w = 0, h = 0;
    glfwGetFramebufferSize(imgui_window, &w, &h);
    if (w <= 0 || h <= 0)
        return false;

    std::vector<unsigned char> pixels((size_t)w * h * 3);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, pixels.data());

    return write_bmp(path, w, h, pixels.data());
}

constexpr uint16_t PORT = 47821;

std::atomic<bool> g_running{false};
std::thread g_thread;
socket_t g_listen_fd = INVALID_SOCK;
socket_t g_client_fd = INVALID_SOCK;

/* The socket thread only ever touches this queue (never ImGui) - pump() is the sole reader,
called from the main thread. */
std::mutex g_queue_mutex;
std::deque<std::string> g_queue;

/* Tracked independently of the real OS keyboard state (this thread has no access to that) so
that ImGuiMod_Ctrl/Shift/Alt/Super can be derived and sent the same way
imgui_impl_glfw.cpp's ImGui_ImplGlfw_UpdateKeyModifiers does - AddKeyEvent on the raw
Left/RightCtrl key alone does not update io.KeyCtrl et al. */
bool g_mod_ctrl_l = false, g_mod_ctrl_r = false;
bool g_mod_shift_l = false, g_mod_shift_r = false;
bool g_mod_alt_l = false, g_mod_alt_r = false;
bool g_mod_super_l = false, g_mod_super_r = false;

bool *modifier_flag(ImGuiKey key) {
    switch (key) {
        case ImGuiKey_LeftCtrl:   return &g_mod_ctrl_l;
        case ImGuiKey_RightCtrl:  return &g_mod_ctrl_r;
        case ImGuiKey_LeftShift:  return &g_mod_shift_l;
        case ImGuiKey_RightShift: return &g_mod_shift_r;
        case ImGuiKey_LeftAlt:    return &g_mod_alt_l;
        case ImGuiKey_RightAlt:   return &g_mod_alt_r;
        case ImGuiKey_LeftSuper:  return &g_mod_super_l;
        case ImGuiKey_RightSuper: return &g_mod_super_r;
        default: return nullptr;
    }
}

void update_modifier_state(ImGuiIO& io) {
    io.AddKeyEvent(ImGuiMod_Ctrl,  g_mod_ctrl_l  || g_mod_ctrl_r);
    io.AddKeyEvent(ImGuiMod_Shift, g_mod_shift_l || g_mod_shift_r);
    io.AddKeyEvent(ImGuiMod_Alt,   g_mod_alt_l   || g_mod_alt_r);
    io.AddKeyEvent(ImGuiMod_Super, g_mod_super_l || g_mod_super_r);
}

ImGuiKey key_from_name(const std::string& name) {
    auto it = virt_composer::imgui_key_from_str.find(name);
    return it != virt_composer::imgui_key_from_str.end() ? it->second : ImGuiKey_None;
}

/*! Commands (one per line, plaintext, space-separated):
 *    key_down <ImGuiKeyName>  / key_up <ImGuiKeyName>  / key_press <ImGuiKeyName>
 *    char <single-char>       / char <codepoint-int>
 *    text <rest of the line, inserted char by char>
 *    mouse_pos <x> <y>
 *    mouse_down <0|1|2>       / mouse_up <0|1|2>       / mouse_click <0|1|2>
 *    mouse_wheel <x> <y>
 *    screenshot <path>       - captures the current framebuffer to `path` as a BMP (see
 *                               capture_screenshot() - works even if the window is hidden/never
 *                               shown, e.g. under VC_WINDOW_STAY_HIDDEN)
 * Unknown/malformed lines are ignored (DBG-logged) - this is a debug tool, not a protocol to be
 * strict about.
 *
 * Only ever called from pump(), on the main thread - see the NOTE in debug_input_pipe.h for why. */
void dispatch_line(const std::string& line) {
    std::istringstream iss(line);
    std::string cmd;
    iss >> cmd;
    if (cmd.empty())
        return;

    ImGuiIO& io = ImGui::GetIO();

    if (cmd == "key_down" || cmd == "key_up" || cmd == "key_press") {
        std::string key_name;
        iss >> key_name;
        ImGuiKey key = key_from_name(key_name);
        if (key == ImGuiKey_None) {
            DBG("debug_input_pipe: unknown key '%s'", key_name.c_str());
            return;
        }
        auto apply = [&](bool down) {
            io.AddKeyEvent(key, down);
            if (bool *flag = modifier_flag(key)) {
                *flag = down;
                update_modifier_state(io);
            }
        };
        if (cmd == "key_down")      apply(true);
        else if (cmd == "key_up")   apply(false);
        else                        { apply(true); apply(false); }
    }
    else if (cmd == "char") {
        std::string rest;
        std::getline(iss, rest);
        if (!rest.empty() && rest[0] == ' ')
            rest = rest.substr(1);
        if (rest.size() == 1)
            io.AddInputCharacter((unsigned int)(unsigned char)rest[0]);
        else if (!rest.empty())
            io.AddInputCharacter((unsigned int)std::strtoul(rest.c_str(), nullptr, 10));
    }
    else if (cmd == "text") {
        std::string rest;
        std::getline(iss, rest);
        if (!rest.empty() && rest[0] == ' ')
            rest = rest.substr(1);
        for (unsigned char c : rest)
            io.AddInputCharacter((unsigned int)c);
    }
    else if (cmd == "mouse_pos") {
        float x = 0, y = 0;
        iss >> x >> y;
        io.AddMousePosEvent(x, y);
    }
    else if (cmd == "mouse_down" || cmd == "mouse_up" || cmd == "mouse_click") {
        int button = 0;
        iss >> button;
        if (cmd == "mouse_down")      io.AddMouseButtonEvent(button, true);
        else if (cmd == "mouse_up")   io.AddMouseButtonEvent(button, false);
        else { io.AddMouseButtonEvent(button, true); io.AddMouseButtonEvent(button, false); }
    }
    else if (cmd == "mouse_wheel") {
        float x = 0, y = 0;
        iss >> x >> y;
        io.AddMouseWheelEvent(x, y);
    }
    else if (cmd == "screenshot") {
        std::string path;
        std::getline(iss, path);
        if (!path.empty() && path[0] == ' ')
            path = path.substr(1);
        if (path.empty()) {
            DBG("debug_input_pipe: 'screenshot' needs a path");
        } else if (!capture_screenshot(path.c_str())) {
            DBG("debug_input_pipe: screenshot capture/write failed for '%s'", path.c_str());
        }
    }
    else {
        DBG("debug_input_pipe: unknown command '%s'", cmd.c_str());
    }
}

void server_loop() {
    while (g_running.load()) {
        sockaddr_in client_addr{};
#ifdef _WIN32
        int addr_len = sizeof(client_addr);
#else
        socklen_t addr_len = sizeof(client_addr);
#endif
        socket_t client = accept(g_listen_fd, (sockaddr *)&client_addr, &addr_len);
        if (client == INVALID_SOCK)
            break; /* listen socket closed by uninit(), or a real error - either way, stop */
        g_client_fd = client;

        std::string buffer;
        char chunk[512];
        while (g_running.load()) {
            int n = recv(client, chunk, sizeof(chunk), 0);
            if (n <= 0)
                break;
            buffer.append(chunk, (size_t)n);

            size_t pos;
            while ((pos = buffer.find('\n')) != std::string::npos) {
                std::string line = buffer.substr(0, pos);
                buffer.erase(0, pos + 1);
                if (!line.empty() && line.back() == '\r')
                    line.pop_back();
                std::lock_guard<std::mutex> lock(g_queue_mutex);
                g_queue.push_back(std::move(line));
            }
        }

        CLOSESOCK(client);
        g_client_fd = INVALID_SOCK;
    }
}

} /* anonymous namespace */

int init() {
#ifdef _WIN32
    WSADATA wsa_data;
    if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) {
        DBG("debug_input_pipe: WSAStartup failed");
        return -1;
    }
#endif

    g_listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (g_listen_fd == INVALID_SOCK) {
        DBG("debug_input_pipe: socket() failed");
        return -1;
    }

    int reuse = 1;
    setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons(PORT);

    if (bind(g_listen_fd, (sockaddr *)&addr, sizeof(addr)) != 0) {
        DBG("debug_input_pipe: bind() failed on 127.0.0.1:%d", (int)PORT);
        CLOSESOCK(g_listen_fd);
        g_listen_fd = INVALID_SOCK;
        return -1;
    }

    if (listen(g_listen_fd, 1) != 0) {
        DBG("debug_input_pipe: listen() failed");
        CLOSESOCK(g_listen_fd);
        g_listen_fd = INVALID_SOCK;
        return -1;
    }

    g_running = true;
    g_thread = std::thread(server_loop);

    DBG("debug_input_pipe: listening on 127.0.0.1:%d", (int)PORT);
    return 0;
}

void pump() {
    std::deque<std::string> lines;
    {
        std::lock_guard<std::mutex> lock(g_queue_mutex);
        lines.swap(g_queue);
    }
    for (auto& line : lines)
        dispatch_line(line);
}

void uninit() {
    g_running = false;

    if (g_client_fd != INVALID_SOCK)
        CLOSESOCK(g_client_fd);
    if (g_listen_fd != INVALID_SOCK)
        CLOSESOCK(g_listen_fd);
    g_listen_fd = INVALID_SOCK;
    g_client_fd = INVALID_SOCK;

    if (g_thread.joinable())
        g_thread.join();

#ifdef _WIN32
    WSACleanup();
#endif
}

void hide_console() {
#ifdef _WIN32
    if (getenv("VC_WINDOW_START_HIDDEN")) {
        HWND console = GetConsoleWindow();
        if (console)
            ShowWindow(console, SW_HIDE);
    }
#endif
}

void reveal_window() {
    if (getenv("VC_WINDOW_START_HIDDEN")) {
        if (const char *pos = getenv("MATH_WRITER_DEV_WINDOW_POS")) {
            int x = 0, y = 0;
            if (sscanf(pos, "%d,%d", &x, &y) == 2)
                glfwSetWindowPos(imgui_window, x, y);
        }
        /* VC_WINDOW_STAY_HIDDEN: for fully headless automated driving - never show the window at
        all, ever (position it anyway, harmlessly, in case something later does reveal it some
        other way). Rendering still happens every frame regardless (glfwSwapBuffers() doesn't
        care whether the window is visible) - use the "screenshot" debug_input_pipe command to see
        what's on screen instead of ever showing a real window. */
        if (getenv("VC_WINDOW_STAY_HIDDEN"))
            return;
#ifdef _WIN32
        /* SW_SHOWNOACTIVATE, not glfwShowWindow() - see the #include comment above for why. */
        ShowWindow(glfwGetWin32Window(imgui_window), SW_SHOWNOACTIVATE);
#else
        glfwShowWindow(imgui_window);
#endif
    }
}

} /* namespace debug_input_pipe */
