#include "media_io_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <winhttp.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodCall = flutter::MethodCall<EncodableValue>;
using MethodResult = flutter::MethodResult<EncodableValue>;

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) {
    return {};
  }
  std::wstring result(static_cast<size_t>(size), L'\0');
  if (MultiByteToWideChar(
          CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
          static_cast<int>(text.size()), result.data(), size) != size) {
    return {};
  }
  return result;
}

const EncodableValue* MapValue(
    const EncodableMap* map, const std::string& key) {
  if (map == nullptr) {
    return nullptr;
  }
  const auto found = map->find(EncodableValue(key));
  return found == map->end() ? nullptr : &found->second;
}

std::string StringValue(
    const EncodableMap* map, const std::string& key) {
  const auto* value = MapValue(map, key);
  if (value == nullptr) {
    return {};
  }
  const auto* text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

int64_t IntValue(
    const EncodableMap* map, const std::string& key, int64_t fallback = 0) {
  const auto* value = MapValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  return fallback;
}

std::unordered_map<std::string, std::string> StringMapValue(
    const EncodableMap* map, const std::string& key) {
  std::unordered_map<std::string, std::string> result;
  const auto* value = MapValue(map, key);
  if (value == nullptr) {
    return result;
  }
  const auto* encoded_map = std::get_if<EncodableMap>(value);
  if (encoded_map == nullptr) {
    return result;
  }
  for (const auto& entry : *encoded_map) {
    const auto* header_name = std::get_if<std::string>(&entry.first);
    const auto* header_value = std::get_if<std::string>(&entry.second);
    if (header_name != nullptr && header_value != nullptr) {
      result.emplace(*header_name, *header_value);
    }
  }
  return result;
}

std::string WinHttpError(const char* operation) {
  return std::string(operation) + " failed (Win32 " +
         std::to_string(GetLastError()) + ")";
}

bool FileLength(const std::wstring& path, uint64_t* length) {
  WIN32_FILE_ATTRIBUTE_DATA data{};
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) {
    if (GetLastError() == ERROR_FILE_NOT_FOUND ||
        GetLastError() == ERROR_PATH_NOT_FOUND) {
      *length = 0;
      return true;
    }
    return false;
  }
  ULARGE_INTEGER size{};
  size.HighPart = data.nFileSizeHigh;
  size.LowPart = data.nFileSizeLow;
  *length = size.QuadPart;
  return true;
}

bool EnsureParentDirectory(const std::wstring& path) {
  std::error_code error;
  const auto parent = std::filesystem::path(path).parent_path();
  if (parent.empty()) {
    return true;
  }
  std::filesystem::create_directories(parent, error);
  return !error;
}

bool QueryNumericHeader(
    HINTERNET request, DWORD query, DWORD* value) {
  DWORD size = sizeof(*value);
  return WinHttpQueryHeaders(
             request, query | WINHTTP_QUERY_FLAG_NUMBER,
             WINHTTP_HEADER_NAME_BY_INDEX, value, &size,
             WINHTTP_NO_HEADER_INDEX) != FALSE;
}

std::wstring QueryStringHeader(HINTERNET request, DWORD query) {
  DWORD size = 0;
  WinHttpQueryHeaders(
      request, query, WINHTTP_HEADER_NAME_BY_INDEX, nullptr, &size,
      WINHTTP_NO_HEADER_INDEX);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || size < sizeof(wchar_t)) {
    return {};
  }
  std::vector<wchar_t> buffer(size / sizeof(wchar_t));
  if (!WinHttpQueryHeaders(
          request, query, WINHTTP_HEADER_NAME_BY_INDEX, buffer.data(), &size,
          WINHTTP_NO_HEADER_INDEX)) {
    return {};
  }
  return std::wstring(buffer.data());
}

int64_t ParseUnsigned(const std::wstring& text) {
  if (text.empty()) {
    return -1;
  }
  wchar_t* end = nullptr;
  const unsigned long long value = wcstoull(text.c_str(), &end, 10);
  if (end == text.c_str() || *end != L'\0' ||
      value > static_cast<unsigned long long>(INT64_MAX)) {
    return -1;
  }
  return static_cast<int64_t>(value);
}

int64_t ExpectedLengthFromResponse(
    HINTERNET request, uint64_t existing_bytes) {
  const auto content_range =
      QueryStringHeader(request, WINHTTP_QUERY_CONTENT_RANGE);
  const auto slash = content_range.rfind(L'/');
  if (slash != std::wstring::npos && slash + 1 < content_range.size()) {
    const auto total = ParseUnsigned(content_range.substr(slash + 1));
    if (total >= 0) {
      return total;
    }
  }
  const auto content_length =
      ParseUnsigned(QueryStringHeader(request, WINHTTP_QUERY_CONTENT_LENGTH));
  if (content_length < 0 ||
      existing_bytes > static_cast<uint64_t>(INT64_MAX - content_length)) {
    return -1;
  }
  return static_cast<int64_t>(existing_bytes) + content_length;
}

struct ParsedUrl {
  std::wstring host;
  std::wstring path;
  INTERNET_PORT port = 0;
  bool secure = false;
};

bool ParseUrl(const std::wstring& url, ParsedUrl* parsed) {
  URL_COMPONENTS components{};
  components.dwStructSize = sizeof(components);
  components.dwHostNameLength = static_cast<DWORD>(-1);
  components.dwUrlPathLength = static_cast<DWORD>(-1);
  components.dwExtraInfoLength = static_cast<DWORD>(-1);
  if (!WinHttpCrackUrl(url.c_str(), 0, 0, &components)) {
    return false;
  }
  parsed->host.assign(components.lpszHostName, components.dwHostNameLength);
  parsed->path.assign(components.lpszUrlPath, components.dwUrlPathLength);
  if (components.dwExtraInfoLength > 0) {
    parsed->path.append(
        components.lpszExtraInfo, components.dwExtraInfoLength);
  }
  if (parsed->path.empty()) {
    parsed->path = L"/";
  }
  parsed->port = components.nPort;
  parsed->secure = components.nScheme == INTERNET_SCHEME_HTTPS;
  return !parsed->host.empty();
}

enum class DownloadStatus {
  kStarting,
  kRunning,
  kFinished,
  kPreempted,
  kFailed,
};

const char* DownloadStatusName(DownloadStatus status) {
  switch (status) {
    case DownloadStatus::kStarting:
      return "starting";
    case DownloadStatus::kRunning:
      return "running";
    case DownloadStatus::kFinished:
      return "finished";
    case DownloadStatus::kPreempted:
      return "preempted";
    case DownloadStatus::kFailed:
      return "failed";
  }
  return "failed";
}

struct DownloadSnapshot {
  int64_t id = 0;
  DownloadStatus status = DownloadStatus::kStarting;
  int64_t total_length = -1;
  uint64_t downloaded_bytes = 0;
  uint64_t persisted_bytes = 0;
  uint64_t received_bytes = 0;
  uint64_t peak_buffered_bytes = 0;
  int status_code = 0;
  uint64_t read_calls = 0;
  uint64_t write_calls = 0;
  std::string error;
};

class NativeDownload : public std::enable_shared_from_this<NativeDownload> {
 public:
  NativeDownload(
      HINTERNET session, int64_t id, std::wstring url,
      std::wstring local_path,
      std::unordered_map<std::string, std::string> headers,
      uint64_t initial_flush_bytes)
      : session_(session),
        id_(id),
        url_(std::move(url)),
        local_path_(std::move(local_path)),
        headers_(std::move(headers)),
        initial_flush_bytes_(initial_flush_bytes) {}

  ~NativeDownload() { Join(); }

  void Start() {
    auto self = shared_from_this();
    thread_ = std::thread([self]() { self->Run(); });
  }

  void Cancel() {
    cancelled_.store(true, std::memory_order_release);
    HINTERNET request = nullptr;
    {
      std::lock_guard<std::mutex> lock(request_mutex_);
      request = request_;
      request_ = nullptr;
    }
    if (request != nullptr) {
      WinHttpCloseHandle(request);
    }
  }

  void Join() {
    if (thread_.joinable()) {
      thread_.join();
    }
  }

  DownloadSnapshot Snapshot() const {
    std::lock_guard<std::mutex> lock(state_mutex_);
    return state_;
  }

 private:
  void Fail(const std::string& message, int status_code = 0) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_.status = cancelled_.load(std::memory_order_acquire)
                        ? DownloadStatus::kPreempted
                        : DownloadStatus::kFailed;
    state_.status_code = status_code;
    state_.error = message;
  }

  void SetStatus(DownloadStatus status) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_.status = status;
  }

  void CloseRequest(HINTERNET request) {
    bool owns_handle = false;
    {
      std::lock_guard<std::mutex> lock(request_mutex_);
      if (request_ == request) {
        request_ = nullptr;
        owns_handle = true;
      }
    }
    if (owns_handle) {
      WinHttpCloseHandle(request);
    }
  }

  void Run() {
    // Media transfer work must yield to Flutter presentation, Show and Cast.
    // This changes only this native worker thread's CPU scheduling priority;
    // it does not cap network throughput or alter the process/GPU policy.
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      state_.id = id_;
      state_.status = DownloadStatus::kStarting;
    }
    const std::wstring part_path = local_path_ + L".part";
    if (!EnsureParentDirectory(part_path)) {
      Fail("Unable to create the cache directory");
      return;
    }
    uint64_t existing_bytes = 0;
    if (!FileLength(part_path, &existing_bytes)) {
      Fail("Unable to inspect the partial file");
      return;
    }

    ParsedUrl parsed;
    if (!ParseUrl(url_, &parsed)) {
      Fail("Invalid HTTP URL");
      return;
    }
    HINTERNET connection = WinHttpConnect(
        session_, parsed.host.c_str(), parsed.port, 0);
    if (connection == nullptr) {
      Fail(WinHttpError("WinHttpConnect"));
      return;
    }
    const DWORD flags = parsed.secure ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET request = WinHttpOpenRequest(
        connection, L"GET", parsed.path.c_str(), nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (request == nullptr) {
      Fail(WinHttpError("WinHttpOpenRequest"));
      WinHttpCloseHandle(connection);
      return;
    }
    {
      std::lock_guard<std::mutex> lock(request_mutex_);
      if (cancelled_.load(std::memory_order_acquire)) {
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connection);
        SetStatus(DownloadStatus::kPreempted);
        return;
      }
      request_ = request;
    }

    for (const auto& header : headers_) {
      const auto wide_name = Utf8ToWide(header.first);
      const auto wide_value = Utf8ToWide(header.second);
      if (wide_name.empty()) {
        continue;
      }
      const std::wstring line = wide_name + L": " + wide_value;
      WinHttpAddRequestHeaders(
          request, line.c_str(), static_cast<DWORD>(-1),
          WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
    }
    if (existing_bytes > 0) {
      const std::wstring range =
          L"Range: bytes=" + std::to_wstring(existing_bytes) + L"-";
      WinHttpAddRequestHeaders(
          request, range.c_str(), static_cast<DWORD>(-1),
          WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
    }

    BOOL sent = WinHttpSendRequest(
        request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
        WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    if (sent) {
      sent = WinHttpReceiveResponse(request, nullptr);
    }
    if (!sent) {
      Fail(WinHttpError("WinHttpSendRequest/ReceiveResponse"));
      CloseRequest(request);
      WinHttpCloseHandle(connection);
      return;
    }
    DWORD status_code = 0;
    if (!QueryNumericHeader(request, WINHTTP_QUERY_STATUS_CODE, &status_code)) {
      Fail(WinHttpError("WinHttpQueryHeaders"));
      CloseRequest(request);
      WinHttpCloseHandle(connection);
      return;
    }
    constexpr DWORD kHttpStatusRangeNotSatisfiable = 416;
    if (status_code == kHttpStatusRangeNotSatisfiable && existing_bytes > 0) {
      std::lock_guard<std::mutex> lock(state_mutex_);
      state_.status = DownloadStatus::kFinished;
      state_.status_code = static_cast<int>(status_code);
      state_.total_length = static_cast<int64_t>(existing_bytes);
      state_.downloaded_bytes = existing_bytes;
      state_.persisted_bytes = existing_bytes;
      CloseRequest(request);
      WinHttpCloseHandle(connection);
      return;
    }
    if (status_code != HTTP_STATUS_OK &&
        status_code != HTTP_STATUS_PARTIAL_CONTENT) {
      Fail("Server returned HTTP " + std::to_string(status_code),
           static_cast<int>(status_code));
      CloseRequest(request);
      WinHttpCloseHandle(connection);
      return;
    }
    const bool append = status_code == HTTP_STATUS_PARTIAL_CONTENT &&
                        existing_bytes > 0;
    if (!append) {
      existing_bytes = 0;
    }
    const int64_t expected_length =
        ExpectedLengthFromResponse(request, existing_bytes);

    HANDLE file = CreateFileW(
        part_path.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      Fail("Unable to open the partial file");
      CloseRequest(request);
      WinHttpCloseHandle(connection);
      return;
    }
    LARGE_INTEGER position{};
    position.QuadPart = append ? static_cast<LONGLONG>(existing_bytes) : 0;
    if (!SetFilePointerEx(file, position, nullptr, FILE_BEGIN) ||
        (!append && !SetEndOfFile(file))) {
      Fail("Unable to position the partial file");
      CloseHandle(file);
      CloseRequest(request);
      WinHttpCloseHandle(connection);
      return;
    }
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      state_.status = DownloadStatus::kRunning;
      state_.status_code = static_cast<int>(status_code);
      state_.total_length = expected_length;
      state_.downloaded_bytes = existing_bytes;
      state_.persisted_bytes = existing_bytes;
    }

    constexpr size_t kWriteBatchBytes = 1024 * 1024;
    std::vector<uint8_t> buffer(kWriteBatchBytes);
    size_t buffered_bytes = 0;
    auto buffered_since = std::chrono::steady_clock::time_point{};
    size_t write_threshold = static_cast<size_t>(initial_flush_bytes_);
    if (write_threshold == 0 || write_threshold > kWriteBatchBytes) {
      write_threshold = kWriteBatchBytes;
    }
    auto persist_buffer = [&]() {
      if (buffered_bytes == 0) {
        return true;
      }
      DWORD written = 0;
      if (!WriteFile(
              file, buffer.data(), static_cast<DWORD>(buffered_bytes),
              &written, nullptr) || written != buffered_bytes) {
        Fail("WriteFile failed (Win32 " +
             std::to_string(GetLastError()) + ")");
        return false;
      }
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        state_.persisted_bytes += written;
        state_.write_calls++;
      }
      buffered_bytes = 0;
      buffered_since = std::chrono::steady_clock::time_point{};
      write_threshold = kWriteBatchBytes;
      return true;
    };
    bool io_ok = true;
    while (!cancelled_.load(std::memory_order_acquire)) {
      DWORD available_bytes = 0;
      if (!WinHttpQueryDataAvailable(request, &available_bytes)) {
        if (!cancelled_.load(std::memory_order_acquire)) {
          Fail(WinHttpError("WinHttpQueryDataAvailable"));
        }
        io_ok = false;
        break;
      }
      if (available_bytes == 0) {
        if (!persist_buffer()) {
          io_ok = false;
        }
        break;
      }
      const size_t remaining_capacity = buffer.size() - buffered_bytes;
      const DWORD bytes_to_read =
          available_bytes < remaining_capacity
              ? available_bytes
              : static_cast<DWORD>(remaining_capacity);
      DWORD bytes_read = 0;
      if (!WinHttpReadData(
              request, buffer.data() + buffered_bytes,
              bytes_to_read, &bytes_read)) {
        if (!cancelled_.load(std::memory_order_acquire)) {
          Fail(WinHttpError("WinHttpReadData"));
        }
        io_ok = false;
        break;
      }
      if (bytes_read == 0) {
        continue;
      }
      if (buffered_bytes == 0) {
        buffered_since = std::chrono::steady_clock::now();
      }
      buffered_bytes += bytes_read;
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        state_.downloaded_bytes += bytes_read;
        state_.received_bytes += bytes_read;
        state_.read_calls++;
        if (buffered_bytes > state_.peak_buffered_bytes) {
          state_.peak_buffered_bytes = buffered_bytes;
        }
      }
      // Keep large sequential writes on fast links, but do not leave a small
      // tail invisible to the progressive HTTP reader for seconds. This is a
      // normal WriteFile only; deliberately avoid FlushFileBuffers here.
      constexpr auto kMaxBufferedLatency = std::chrono::milliseconds(200);
      const bool latency_elapsed =
          buffered_since != std::chrono::steady_clock::time_point{} &&
          std::chrono::steady_clock::now() - buffered_since >=
              kMaxBufferedLatency;
      if ((buffered_bytes >= write_threshold || latency_elapsed) &&
          !persist_buffer()) {
        io_ok = false;
        break;
      }
    }
    CloseHandle(file);
    CloseRequest(request);
    WinHttpCloseHandle(connection);

    if (cancelled_.load(std::memory_order_acquire)) {
      SetStatus(DownloadStatus::kPreempted);
      return;
    }
    if (!io_ok) {
      return;
    }
    uint64_t actual_length = 0;
    if (!FileLength(part_path, &actual_length)) {
      Fail("Unable to inspect the completed partial file");
      return;
    }
    if (expected_length >= 0 &&
        actual_length < static_cast<uint64_t>(expected_length)) {
      Fail("Download ended early: " + std::to_string(actual_length) + "/" +
           std::to_string(expected_length) + " bytes");
      return;
    }
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      state_.status = DownloadStatus::kFinished;
      state_.total_length = static_cast<int64_t>(actual_length);
      state_.downloaded_bytes = actual_length;
      state_.persisted_bytes = actual_length;
    }
  }

  HINTERNET session_ = nullptr;
  int64_t id_ = 0;
  std::wstring url_;
  std::wstring local_path_;
  std::unordered_map<std::string, std::string> headers_;
  uint64_t initial_flush_bytes_ = 1024 * 1024;
  std::atomic<bool> cancelled_{false};
  mutable std::mutex state_mutex_;
  DownloadSnapshot state_;
  std::mutex request_mutex_;
  HINTERNET request_ = nullptr;
  std::thread thread_;
};

class MediaIoRuntime {
 public:
  MediaIoRuntime() {
    session_ = WinHttpOpen(
        L"Kirakara/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (session_ != nullptr) {
      WinHttpSetTimeouts(session_, 5000, 10000, 10000, 15000);
    }
  }

  ~MediaIoRuntime() { Shutdown(); }

  bool available() const { return session_ != nullptr; }

  bool Start(
      int64_t id, const std::string& url, const std::string& local_path,
      std::unordered_map<std::string, std::string> headers,
      uint64_t initial_flush_bytes) {
    if (session_ == nullptr || id <= 0) {
      return false;
    }
    const auto wide_url = Utf8ToWide(url);
    const auto wide_path = Utf8ToWide(local_path);
    if (wide_url.empty() || wide_path.empty()) {
      return false;
    }
    auto task = std::make_shared<NativeDownload>(
        session_, id, wide_url, wide_path, std::move(headers),
        initial_flush_bytes);
    {
      std::lock_guard<std::mutex> lock(tasks_mutex_);
      if (tasks_.find(id) != tasks_.end()) {
        return false;
      }
      tasks_.emplace(id, task);
    }
    task->Start();
    return true;
  }

  void Cancel(int64_t id) {
    const auto task = Find(id);
    if (task != nullptr) {
      task->Cancel();
    }
  }

  EncodableList Poll() const {
    std::vector<std::shared_ptr<NativeDownload>> tasks;
    {
      std::lock_guard<std::mutex> lock(tasks_mutex_);
      tasks.reserve(tasks_.size());
      for (const auto& entry : tasks_) {
        tasks.push_back(entry.second);
      }
    }
    EncodableList result;
    result.reserve(tasks.size());
    for (const auto& task : tasks) {
      const auto state = task->Snapshot();
      EncodableMap encoded;
      encoded.emplace(EncodableValue("id"), EncodableValue(state.id));
      encoded.emplace(
          EncodableValue("status"),
          EncodableValue(std::string(DownloadStatusName(state.status))));
      if (state.total_length >= 0) {
        encoded.emplace(
            EncodableValue("totalLength"),
            EncodableValue(state.total_length));
      }
      encoded.emplace(
          EncodableValue("downloadedBytes"),
          EncodableValue(static_cast<int64_t>(state.downloaded_bytes)));
      encoded.emplace(
          EncodableValue("persistedBytes"),
          EncodableValue(static_cast<int64_t>(state.persisted_bytes)));
      encoded.emplace(
          EncodableValue("receivedBytes"),
          EncodableValue(static_cast<int64_t>(state.received_bytes)));
      encoded.emplace(
          EncodableValue("statusCode"),
          EncodableValue(static_cast<int64_t>(state.status_code)));
      encoded.emplace(
          EncodableValue("readCalls"),
          EncodableValue(static_cast<int64_t>(state.read_calls)));
      encoded.emplace(
          EncodableValue("writeCalls"),
          EncodableValue(static_cast<int64_t>(state.write_calls)));
      encoded.emplace(
          EncodableValue("peakBufferedBytes"),
          EncodableValue(static_cast<int64_t>(state.peak_buffered_bytes)));
      if (!state.error.empty()) {
        encoded.emplace(
            EncodableValue("error"), EncodableValue(state.error));
      }
      result.emplace_back(encoded);
    }
    return result;
  }

  void Release(int64_t id) {
    std::shared_ptr<NativeDownload> task;
    {
      std::lock_guard<std::mutex> lock(tasks_mutex_);
      const auto found = tasks_.find(id);
      if (found == tasks_.end()) {
        return;
      }
      task = found->second;
      tasks_.erase(found);
    }
    task->Join();
  }

  void Shutdown() {
    std::vector<std::shared_ptr<NativeDownload>> tasks;
    {
      std::lock_guard<std::mutex> lock(tasks_mutex_);
      for (const auto& entry : tasks_) {
        tasks.push_back(entry.second);
      }
      tasks_.clear();
    }
    for (const auto& task : tasks) {
      task->Cancel();
    }
    for (const auto& task : tasks) {
      task->Join();
    }
    if (session_ != nullptr) {
      WinHttpCloseHandle(session_);
      session_ = nullptr;
    }
  }

 private:
  std::shared_ptr<NativeDownload> Find(int64_t id) const {
    std::lock_guard<std::mutex> lock(tasks_mutex_);
    const auto found = tasks_.find(id);
    return found == tasks_.end() ? nullptr : found->second;
  }

  HINTERNET session_ = nullptr;
  mutable std::mutex tasks_mutex_;
  std::unordered_map<int64_t, std::shared_ptr<NativeDownload>> tasks_;
};

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_media_io_channel;
std::unique_ptr<MediaIoRuntime> g_media_io_runtime;

void HandleMethodCall(
    const MethodCall& call, std::unique_ptr<MethodResult> result) {
  const auto* arguments =
      call.arguments() == nullptr
          ? nullptr
          : std::get_if<EncodableMap>(call.arguments());
  if (call.method_name() == "probe") {
    EncodableMap value;
    value.emplace(EncodableValue("version"), EncodableValue(int32_t{1}));
    value.emplace(
        EncodableValue("backend"), EncodableValue("winhttp"));
    value.emplace(
        EncodableValue("available"),
        EncodableValue(g_media_io_runtime != nullptr &&
                       g_media_io_runtime->available()));
    result->Success(value);
    return;
  }
  if (g_media_io_runtime == nullptr || !g_media_io_runtime->available()) {
    result->Error("unavailable", "WinHTTP media backend is unavailable");
    return;
  }
  if (call.method_name() == "start") {
    const auto id = IntValue(arguments, "id");
    const auto initial_flush_bytes =
        IntValue(arguments, "initialFlushBytes", 1024 * 1024);
    const bool started = g_media_io_runtime->Start(
        id, StringValue(arguments, "url"),
        StringValue(arguments, "localPath"),
        StringMapValue(arguments, "headers"),
        initial_flush_bytes > 0
            ? static_cast<uint64_t>(initial_flush_bytes)
            : static_cast<uint64_t>(1024 * 1024));
    if (!started) {
      result->Error("start_failed", "Unable to start native download");
    } else {
      result->Success(EncodableValue(true));
    }
    return;
  }
  if (call.method_name() == "cancel") {
    g_media_io_runtime->Cancel(IntValue(arguments, "id"));
    result->Success();
    return;
  }
  if (call.method_name() == "poll") {
    result->Success(g_media_io_runtime->Poll());
    return;
  }
  if (call.method_name() == "release") {
    g_media_io_runtime->Release(IntValue(arguments, "id"));
    result->Success();
    return;
  }
  if (call.method_name() == "shutdown") {
    g_media_io_runtime->Shutdown();
    result->Success();
    return;
  }
  result->NotImplemented();
}

}  // namespace

void RegisterMediaIoBridge(flutter::BinaryMessenger* messenger) {
  g_media_io_runtime = std::make_unique<MediaIoRuntime>();
  g_media_io_channel =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "kirakara/media_io",
          &flutter::StandardMethodCodec::GetInstance());
  g_media_io_channel->SetMethodCallHandler(HandleMethodCall);
}

void ShutdownMediaIoBridge() {
  g_media_io_channel.reset();
  g_media_io_runtime.reset();
}
