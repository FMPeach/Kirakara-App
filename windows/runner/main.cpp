#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <chrono>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <system_error>

#include "flutter_window.h"
#include "ime_bridge.h"
#include "utils.h"

namespace {

constexpr wchar_t kLegacyCacheDirectoryPrefix[] = L"kirakara_cache_";
constexpr wchar_t kSessionDirectoryPrefix[] = L"session_";
constexpr wchar_t kSessionMarkerPrefix[] = L"kirakara_cache_session_";
constexpr wchar_t kSessionMarkerSuffix[] = L".path";

std::optional<std::filesystem::path> GetSystemTempDirectory() {
  std::wstring buffer(MAX_PATH + 1, L'\0');
  const DWORD length =
      ::GetTempPathW(static_cast<DWORD>(buffer.size()), buffer.data());
  if (length == 0) {
    return std::nullopt;
  }
  if (length >= buffer.size()) {
    buffer.resize(length + 1);
    const DWORD retry_length =
        ::GetTempPathW(static_cast<DWORD>(buffer.size()), buffer.data());
    if (retry_length == 0 || retry_length >= buffer.size()) {
      return std::nullopt;
    }
    buffer.resize(retry_length);
  } else {
    buffer.resize(length);
  }
  return std::filesystem::path(buffer);
}

std::optional<DWORD> ProcessIdFromName(const std::wstring& name,
                                       const std::wstring& prefix,
                                       const std::wstring& suffix = L"") {
  if (name.size() <= prefix.size() + suffix.size() ||
      name.compare(0, prefix.size(), prefix) != 0 ||
      (!suffix.empty() &&
       name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0)) {
    return std::nullopt;
  }
  const std::wstring id_text =
      name.substr(prefix.size(), name.size() - prefix.size() - suffix.size());
  if (id_text.empty()) {
    return std::nullopt;
  }
  for (const wchar_t character : id_text) {
    if (!std::iswdigit(character)) {
      return std::nullopt;
    }
  }
  try {
    const unsigned long value = std::stoul(id_text);
    if (value == 0 || value > MAXDWORD) {
      return std::nullopt;
    }
    return static_cast<DWORD>(value);
  } catch (...) {
    return std::nullopt;
  }
}

std::optional<DWORD> LegacyCacheOwnerProcessId(
    const std::filesystem::path& path) {
  return ProcessIdFromName(path.filename().wstring(),
                           kLegacyCacheDirectoryPrefix);
}

std::optional<DWORD> SessionMarkerOwnerProcessId(
    const std::filesystem::path& path) {
  return ProcessIdFromName(path.filename().wstring(), kSessionMarkerPrefix,
                           kSessionMarkerSuffix);
}

bool IsProcessRunning(DWORD process_id) {
  HANDLE process = ::OpenProcess(SYNCHRONIZE, FALSE, process_id);
  if (!process) {
    return false;
  }
  const DWORD result = ::WaitForSingleObject(process, 0);
  ::CloseHandle(process);
  return result == WAIT_TIMEOUT;
}

void RemoveCacheDirectory(const std::filesystem::path& path) {
  std::error_code error;
  std::filesystem::remove_all(path, error);
}

std::optional<std::wstring> Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::nullopt;
  }
  const int length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                           value.data(),
                                           static_cast<int>(value.size()),
                                           nullptr, 0);
  if (length <= 0) {
    return std::nullopt;
  }
  std::wstring result(length, L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(),
                            length) != length) {
    return std::nullopt;
  }
  return result;
}

std::optional<std::filesystem::path> ReadSessionTarget(
    const std::filesystem::path& marker, DWORD process_id) {
  std::ifstream stream(marker, std::ios::binary);
  if (!stream) {
    return std::nullopt;
  }
  std::string value((std::istreambuf_iterator<char>(stream)),
                    std::istreambuf_iterator<char>());
  if (value.size() >= 3 && static_cast<unsigned char>(value[0]) == 0xEF &&
      static_cast<unsigned char>(value[1]) == 0xBB &&
      static_cast<unsigned char>(value[2]) == 0xBF) {
    value.erase(0, 3);
  }
  while (!value.empty() &&
         (value.back() == ' ' || value.back() == '\t' ||
          value.back() == '\r' || value.back() == '\n')) {
    value.pop_back();
  }
  size_t start = 0;
  while (start < value.size() &&
         (value[start] == ' ' || value[start] == '\t' ||
          value[start] == '\r' || value[start] == '\n')) {
    ++start;
  }
  if (start > 0) {
    value.erase(0, start);
  }

  const auto wide = Utf8ToWide(value);
  if (!wide) {
    return std::nullopt;
  }
  const std::filesystem::path target(*wide);
  const std::wstring expected_name =
      std::wstring(kSessionDirectoryPrefix) + std::to_wstring(process_id);
  if (!target.is_absolute() || !target.has_parent_path() ||
      target.filename().wstring() != expected_name) {
    return std::nullopt;
  }
  return target.lexically_normal();
}

void CleanupSessionMarker(const std::filesystem::path& marker,
                          DWORD process_id) {
  const auto target = ReadSessionTarget(marker, process_id);
  if (target) {
    RemoveCacheDirectory(*target);
  }
  std::error_code error;
  std::filesystem::remove(marker, error);
}

void CleanupAbandonedSessionMarkers(const std::filesystem::path& temp) {
  std::error_code error;
  std::filesystem::directory_iterator entries(temp, error);
  if (error) {
    return;
  }
  for (const auto& entry : entries) {
    if (!entry.is_regular_file(error)) {
      error.clear();
      continue;
    }
    const auto owner = SessionMarkerOwnerProcessId(entry.path());
    if (!owner) {
      continue;
    }
    if (*owner != ::GetCurrentProcessId() && IsProcessRunning(*owner)) {
      continue;
    }
    CleanupSessionMarker(entry.path(), *owner);
  }
}

void CleanupAbandonedCacheDirectories() {
  const auto temp = GetSystemTempDirectory();
  if (!temp) {
    return;
  }

  CleanupAbandonedSessionMarkers(*temp);

  std::error_code error;
  std::filesystem::directory_iterator entries(*temp, error);
  if (error) {
    return;
  }
  const auto legacy_cutoff = std::filesystem::file_time_type::clock::now() -
                             std::chrono::hours(24);
  for (const auto& entry : entries) {
    if (!entry.is_directory(error)) {
      error.clear();
      continue;
    }
    const std::wstring name = entry.path().filename().wstring();
    const std::wstring prefix(kLegacyCacheDirectoryPrefix);
    if (name.size() < prefix.size() ||
        name.compare(0, prefix.size(), prefix) != 0) {
      continue;
    }

    const auto owner = LegacyCacheOwnerProcessId(entry.path());
    if (owner) {
      if (*owner != ::GetCurrentProcessId() && IsProcessRunning(*owner)) {
        continue;
      }
      RemoveCacheDirectory(entry.path());
      continue;
    }

    // Pre-PID cache directories cannot be associated with a live process.
    // Only reap old ones automatically so a concurrently running legacy build
    // is never disrupted.
    const auto modified = entry.last_write_time(error);
    if (!error && modified < legacy_cutoff) {
      RemoveCacheDirectory(entry.path());
    }
    error.clear();
  }
}

void CleanupCurrentProcessCacheDirectory() {
  const auto temp = GetSystemTempDirectory();
  if (!temp) {
    return;
  }

  const DWORD process_id = ::GetCurrentProcessId();
  CleanupSessionMarker(
      *temp / (std::wstring(kSessionMarkerPrefix) +
               std::to_wstring(process_id) + kSessionMarkerSuffix),
      process_id);

  // Also clean the deterministic temporary directory used by builds from
  // before the configurable cache root was introduced.
  RemoveCacheDirectory(
      *temp / (std::wstring(kLegacyCacheDirectoryPrefix) +
               std::to_wstring(process_id)));
}

class ScopedExecutionState {
 public:
  ScopedExecutionState()
      : active_(::SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED |
                                          ES_DISPLAY_REQUIRED) != 0) {}

  ~ScopedExecutionState() {
    if (active_) {
      ::SetThreadExecutionState(ES_CONTINUOUS);
    }
  }

  ScopedExecutionState(const ScopedExecutionState&) = delete;
  ScopedExecutionState& operator=(const ScopedExecutionState&) = delete;

 private:
  bool active_ = false;
};

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  CleanupAbandonedCacheDirectories();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  if (command_line_arguments.size() >= 2 &&
      command_line_arguments[0] == "--kirakara-ime-probe") {
    const std::wstring output_path =
        std::wstring(command_line_arguments[1].begin(),
                     command_line_arguments[1].end());
    const bool ok = RunImeBridgeSelfTest(output_path);
    ::CoUninitialize();
    return ok ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Keep the controller and every attached stage display awake while the app
  // is running. The previous execution state is restored on every exit path.
  ScopedExecutionState execution_state;

  {
    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1600, 900);
    if (!window.Create(L"kirakara_app", origin, size)) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
  }

  // Flutter and the Show host have released their file handles at this point.
  // Delete once more outside Dart so a late native release cannot strand a
  // session cache on the system drive.
  CleanupCurrentProcessCacheDirectory();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
