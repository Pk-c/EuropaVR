#include "common.hpp"

#include <cstdarg>
#include <cstdio>
#include <ctime>

namespace europavr {

namespace {

fs::path g_module_dir;
fs::path g_payload_dir;
fs::path g_profile_dir;
fs::path g_game_config_dir;
std::wstring g_exe_stem;
std::wstring g_project_name;
std::once_flag g_paths_once;
std::mutex g_log_mutex;

fs::path resolve_known_folder(REFKNOWNFOLDERID id) {
    PWSTR raw = nullptr;
    if (SHGetKnownFolderPath(id, 0, nullptr, &raw) != S_OK) {
        return {};
    }
    fs::path p{raw};
    CoTaskMemFree(raw);
    return p;
}

void init_paths() {
    wchar_t buf[MAX_PATH * 2]{};

    // Our own module handle: the address of this function lives inside us.
    HMODULE self = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&init_paths), &self);
    if (GetModuleFileNameW(self, buf, static_cast<DWORD>(std::size(buf))) != 0) {
        g_module_dir = fs::path{buf}.parent_path();
    }
    g_payload_dir = g_module_dir / L"EuropaVR";

    if (GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(std::size(buf))) != 0) {
        g_exe_stem = fs::path{buf}.stem().wstring();
    }

    const auto appdata = resolve_known_folder(FOLDERID_RoamingAppData);
    if (!appdata.empty() && !g_exe_stem.empty()) {
        g_profile_dir = appdata / L"UnrealVRMod" / g_exe_stem;
    }

    // We sit in <Project>\Binaries\Win64, so the project name is two levels up.
    if (g_module_dir.has_parent_path() && g_module_dir.parent_path().has_parent_path()) {
        g_project_name = g_module_dir.parent_path().parent_path().filename().wstring();
    }

    const auto local = resolve_known_folder(FOLDERID_LocalAppData);
    if (!local.empty() && !g_project_name.empty()) {
        g_game_config_dir = local / g_project_name / L"Saved" / L"Config" / L"WindowsNoEditor";
    }
}

void ensure_paths() { std::call_once(g_paths_once, init_paths); }

} // namespace

const fs::path& module_dir() {
    ensure_paths();
    return g_module_dir;
}

const fs::path& payload_dir() {
    ensure_paths();
    return g_payload_dir;
}

const fs::path& profile_dir() {
    ensure_paths();
    return g_profile_dir;
}

const std::wstring& host_exe_stem() {
    ensure_paths();
    return g_exe_stem;
}

const std::wstring& project_name() {
    ensure_paths();
    return g_project_name;
}

const fs::path& game_config_dir() {
    ensure_paths();
    return g_game_config_dir;
}

void log(const char* fmt, ...) {
    char line[2048];
    va_list args;
    va_start(args, fmt);
    const int n = vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    if (n < 0) {
        return;
    }

    std::scoped_lock lock{g_log_mutex};

    ensure_paths();
    if (g_payload_dir.empty()) {
        return;
    }

    std::error_code ec;
    fs::create_directories(g_payload_dir, ec);

    std::ofstream out{g_payload_dir / L"EuropaVR.log", std::ios::app};
    if (!out) {
        return;
    }

    SYSTEMTIME st{};
    GetLocalTime(&st);
    char stamp[32];
    snprintf(stamp, sizeof(stamp), "%02u:%02u:%02u.%03u", st.wHour, st.wMinute, st.wSecond,
             st.wMilliseconds);
    out << '[' << stamp << "] " << line << '\n';
}

std::wstring setting(const wchar_t* key, const wchar_t* fallback) {
    ensure_paths();
    const auto ini = payload_dir() / L"EuropaVR.ini";
    if (!fs::exists(ini)) {
        return fallback;
    }

    // The file is section-less, so GetPrivateProfileString is of no use here.
    std::wifstream in{ini};
    if (!in) {
        return fallback;
    }

    const std::wstring wanted{key};
    std::wstring line;
    while (std::getline(in, line)) {
        const auto eq = line.find(L'=');
        if (eq == std::wstring::npos) {
            continue;
        }
        auto k = line.substr(0, eq);
        auto v = line.substr(eq + 1);
        const auto trim = [](std::wstring& s) {
            const auto b = s.find_first_not_of(L" \t\r\n");
            const auto e = s.find_last_not_of(L" \t\r\n");
            s = (b == std::wstring::npos) ? L"" : s.substr(b, e - b + 1);
        };
        trim(k);
        trim(v);
        if (_wcsicmp(k.c_str(), wanted.c_str()) == 0) {
            return v;
        }
    }
    return fallback;
}

int setting_int(const wchar_t* key, int fallback) {
    const auto v = setting(key, L"");
    if (v.empty()) {
        return fallback;
    }
    try {
        return std::stoi(v);
    } catch (...) {
        return fallback;
    }
}

bool set_config_value(const fs::path& file, const std::string& key, const std::string& value) {
    std::vector<std::string> lines;

    if (fs::exists(file)) {
        std::ifstream in{file};
        if (!in) {
            return false;
        }
        std::string line;
        while (std::getline(in, line)) {
            if (!line.empty() && line.back() == '\r') {
                line.pop_back();
            }
            lines.push_back(std::move(line));
        }
    }

    bool replaced = false;
    for (auto& line : lines) {
        const auto eq = line.find('=');
        if (eq == std::string::npos) {
            continue;
        }
        if (_stricmp(line.substr(0, eq).c_str(), key.c_str()) == 0) {
            line = key + "=" + value;
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        lines.push_back(key + "=" + value);
    }

    std::error_code ec;
    fs::create_directories(file.parent_path(), ec);

    std::ofstream out{file, std::ios::trunc};
    if (!out) {
        return false;
    }
    for (const auto& line : lines) {
        out << line << '\n';
    }
    return true;
}

bool set_ini_value(const fs::path& file, const wchar_t* section, const wchar_t* key,
                   const wchar_t* value) {
    std::error_code ec;
    fs::create_directories(file.parent_path(), ec);

    const BOOL ok = WritePrivateProfileStringW(section, key, value, file.c_str());
    // Windows caches ini contents; this flushes the write to disk immediately.
    WritePrivateProfileStringW(nullptr, nullptr, nullptr, file.c_str());

    if (ok == FALSE) {
        log("Failed to write [%ls] %ls in %ls (%lu)", section, key, file.c_str(), GetLastError());
    }
    return ok != FALSE;
}

} // namespace europavr
