// EuropaVR - brings UEVR up inside the game process without any user action.
//
// Replicates, in-process, the sequence the UEVR frontend performs on inject:
//   1. load UEVRPluginNullifier.dll and call nullify()   <- must run before step 3
//   2. make sure the UEVR profile exists in %APPDATA%
//   3. load the VR runtime (openxr_loader.dll / openvr_api.dll)
//   4. load UEVRBackend.dll
//
// Step 1 wants to happen as early as possible (before the engine ever looks for
// a VR plugin); steps 3-4 want to happen once the game window is up, which is
// when a manual injection would normally occur. So the two are split apart.

#include "common.hpp"

#include <string>

namespace europavr {
namespace {

struct WindowSearch {
    DWORD pid;
    HWND found;
};

BOOL CALLBACK find_game_window(HWND hwnd, LPARAM param) {
    auto* search = reinterpret_cast<WindowSearch*>(param);

    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != search->pid || !IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER) != nullptr) {
        return TRUE;
    }

    RECT rc{};
    if (!GetClientRect(hwnd, &rc) || rc.right - rc.left < 320 || rc.bottom - rc.top < 240) {
        return TRUE;
    }

    search->found = hwnd;
    return FALSE;
}

// Waits for the game to own a real, visible, non-trivial top-level window.
// Returns false on timeout; the caller carries on regardless, since UEVR's own
// hook monitor will keep retrying anyway.
bool wait_for_game_window(int timeout_ms) {
    const DWORD start = GetTickCount();
    for (;;) {
        WindowSearch search{GetCurrentProcessId(), nullptr};
        EnumWindows(find_game_window, reinterpret_cast<LPARAM>(&search));
        if (search.found != nullptr) {
            log("Game window found (hwnd=%p) after %lu ms", search.found, GetTickCount() - start);
            return true;
        }
        if (static_cast<int>(GetTickCount() - start) > timeout_ms) {
            log("Timed out after %d ms waiting for the game window", timeout_ms);
            return false;
        }
        Sleep(100);
    }
}

// LOAD_WITH_ALTERED_SEARCH_PATH makes the loader resolve the module's own
// dependencies from its directory rather than from the game's Binaries\Win64.
// UEVRBackend.dll statically imports openvr_api.dll, so this is what lets the
// whole payload live in its own tidy subfolder.
HMODULE load_payload(const wchar_t* name) {
    const auto path = payload_dir() / name;
    if (!fs::exists(path)) {
        log("MISSING: %ls", path.c_str());
        return nullptr;
    }

    const HMODULE mod = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (mod == nullptr) {
        log("LoadLibraryEx failed for %ls (GetLastError=%lu)", name, GetLastError());
        return nullptr;
    }

    log("Loaded %ls at %p", name, static_cast<void*>(mod));
    return mod;
}

void run_nullifier() {
    const HMODULE mod = load_payload(L"UEVRPluginNullifier.dll");
    if (mod == nullptr) {
        return;
    }

    using nullify_fn = void(*)();
    const auto nullify = reinterpret_cast<nullify_fn>(GetProcAddress(mod, "nullify"));
    if (nullify == nullptr) {
        log("UEVRPluginNullifier.dll has no nullify export");
        return;
    }

    nullify();
    log("nullify() done - engine-side VR plugins neutralised");
}

// Copies our shipped profile into %APPDATA%\UnrealVRMod\<exe>\ so that a plain
// copy-paste install still arrives with the right settings. Existing files are
// preserved so the player's own tweaks survive, unless the shipped profile
// version changed.
void seed_profile() {
    const auto& dst = profile_dir();
    if (dst.empty()) {
        log("Could not resolve the UEVR profile directory");
        return;
    }

    const auto src = payload_dir() / L"profile";
    std::error_code ec;
    fs::create_directories(dst, ec);

    if (fs::exists(src)) {
        const auto version = setting(L"ProfileVersion", L"1");
        const auto stamp = dst / L"EuropaVR_profile_version.txt";

        bool force = true;
        if (std::wifstream in{stamp}; in) {
            std::wstring current;
            std::getline(in, current);
            force = (current != version);
        }

        auto options = fs::copy_options::recursive;
        options |= force ? fs::copy_options::overwrite_existing : fs::copy_options::skip_existing;

        fs::copy(src, dst, options, ec);
        if (ec) {
            log("Profile seeding failed: %s", ec.message().c_str());
        } else {
            log("Profile seeded into %ls (force=%d)", dst.c_str(), static_cast<int>(force));
            if (std::wofstream out{stamp, std::ios::trunc}; out) {
                out << version << L'\n';
            }
        }
    } else {
        log("No shipped profile at %ls - using whatever UEVR already has", src.c_str());
    }
}

// UE4 mutes the game as soon as its window loses foreground focus: the engine
// reads [Audio] UnfocusedVolumeMultiplier from Engine.ini and defaults it to 0.
// Starting the VR runtime hands the foreground to the SteamVR/OpenXR window, so
// the game goes silent the moment UEVR comes up. Pinning the multiplier to 1.0
// keeps the audio running whatever holds the focus.
//
// This races the engine reading its config, but the write happens within a few
// ms of process start while config loading is much later - and deploy.ps1 writes
// the same value at install time, so the very first launch is covered too.
void fix_unfocused_audio() {
    if (game_config_dir().empty()) {
        log("Could not resolve the game config directory - audio fix skipped");
        return;
    }

    const auto engine_ini = game_config_dir() / L"Engine.ini";
    if (set_ini_value(engine_ini, L"Audio", L"UnfocusedVolumeMultiplier", L"1.0")) {
        log("Audio: [Audio] UnfocusedVolumeMultiplier=1.0 set in %ls", engine_ini.c_str());
    }
}

// UEVR only honours the saved menu state when RememberMenuState is on; with it
// off (the default) the menu pops open on every launch and swallows the input
// until it is dismissed. Turning it on while pinning MenuOpen to false makes the
// game start straight into VR.
void keep_uevr_menu_closed() {
    const auto config = profile_dir() / L"config.txt";
    set_config_value(config, "FrameworkConfig_RememberMenuState", "true");
    set_config_value(config, "FrameworkConfig_MenuOpen", "false");
    log("UEVR menu pinned closed at startup");
}

DWORD WINAPI bootstrap_thread(LPVOID) {
    log("=== EuropaVR bootstrap (host=%ls, project=%ls) ===", host_exe_stem().c_str(),
        project_name().c_str());

    if (setting_int(L"Enabled", 1) == 0) {
        log("Disabled via EuropaVR.ini - standing down");
        return 0;
    }

    // First thing, to beat the engine to its own config file.
    if (setting_int(L"FixUnfocusedAudio", 1) != 0) {
        fix_unfocused_audio();
    }

    if (setting_int(L"Nullify", 1) != 0) {
        run_nullifier();
    }

    seed_profile();

    const auto runtime = setting(L"Runtime", L"openxr_loader.dll");
    if (!profile_dir().empty()) {
        // Runtime file names are plain ASCII, so a byte-wise narrowing is safe.
        std::string runtime_narrow;
        runtime_narrow.reserve(runtime.size());
        for (const wchar_t ch : runtime) {
            runtime_narrow.push_back(static_cast<char>(ch));
        }
        set_config_value(profile_dir() / L"config.txt", "Frontend_RequestedRuntime",
                         runtime_narrow);

        if (setting_int(L"StartWithMenuClosed", 1) != 0) {
            keep_uevr_menu_closed();
        }
    }

    wait_for_game_window(setting_int(L"WindowWaitTimeoutMs", 120000));

    const int delay = setting_int(L"PostWindowDelayMs", 3000);
    if (delay > 0) {
        log("Waiting %d ms before injecting the runtime", delay);
        Sleep(static_cast<DWORD>(delay));
    }

    if (load_payload(runtime.c_str()) == nullptr) {
        log("VR runtime failed to load - aborting");
        return 0;
    }

    if (load_payload(L"UEVRBackend.dll") == nullptr) {
        log("UEVRBackend failed to load - aborting");
        return 0;
    }

    log("=== UEVR is up ===");
    return 0;
}

} // namespace

// Called from DllMain. Must not touch the loader: it only spawns the thread that
// does the real work once the loader lock has been released.
void start_bootstrap() {
    const HANDLE thread = CreateThread(nullptr, 0, bootstrap_thread, nullptr, 0, nullptr);
    if (thread != nullptr) {
        CloseHandle(thread);
    }
}

} // namespace europavr
