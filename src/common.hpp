// EuropaVR - common helpers (paths, logging, tiny ini/config editing)
#pragma once

#include <windows.h>
#include <shlobj.h>

#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

namespace europavr {

namespace fs = std::filesystem;

// Directory containing our own DLL (i.e. the game's Binaries\Win64).
const fs::path& module_dir();

// <module_dir>\EuropaVR : where every file we ship lives.
const fs::path& payload_dir();

// %APPDATA%\UnrealVRMod\<exe stem> : where UEVR reads its profile from.
// Empty path if it could not be resolved.
const fs::path& profile_dir();

// Executable stem of the host process, e.g. "Europa-Win64-Shipping".
const std::wstring& host_exe_stem();

// UE project name, deduced from the <Project>\Binaries\Win64 layout, e.g. "Europa".
const std::wstring& project_name();

// %LOCALAPPDATA%\<Project>\Saved\Config\WindowsNoEditor : the game's own config.
const fs::path& game_config_dir();

void log(const char* fmt, ...);

// Reads <payload_dir>\EuropaVR.ini, section-less "Key=Value".
std::wstring setting(const wchar_t* key, const wchar_t* fallback);
int setting_int(const wchar_t* key, int fallback);

// Sets Key=Value in a UEVR-style flat config file, preserving every other line.
bool set_config_value(const fs::path& file, const std::string& key, const std::string& value);

// Sets [Section] Key=Value in a real, sectioned .ini (the game's Engine.ini).
bool set_ini_value(const fs::path& file, const wchar_t* section, const wchar_t* key,
                   const wchar_t* value);

} // namespace europavr
