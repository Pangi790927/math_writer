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
#include <cstdlib>

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

namespace debug_input_pipe {

namespace {

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
        glfwShowWindow(imgui_window);
    }
}

} /* namespace debug_input_pipe */
