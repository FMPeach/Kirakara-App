#include "ime_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <fstream>
#include <limits>
#include <sstream>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodCall = flutter::MethodCall<EncodableValue>;
using MethodResult = flutter::MethodResult<EncodableValue>;

using Bool = int;
using RimeSessionId = uintptr_t;

struct zinnia_character_t;
struct zinnia_recognizer_t;
struct zinnia_result_t;

extern "C" {
zinnia_character_t* zinnia_character_new();
void zinnia_character_destroy(zinnia_character_t* character);
void zinnia_character_clear(zinnia_character_t* character);
void zinnia_character_set_width(zinnia_character_t* character, size_t width);
void zinnia_character_set_height(zinnia_character_t* character, size_t height);
int zinnia_character_add(zinnia_character_t* character, size_t id, int x,
                         int y);

zinnia_recognizer_t* zinnia_recognizer_new();
void zinnia_recognizer_destroy(zinnia_recognizer_t* recognizer);
int zinnia_recognizer_open_from_ptr(zinnia_recognizer_t* recognizer,
                                    const char* ptr, size_t size);
const char* zinnia_recognizer_strerror(zinnia_recognizer_t* recognizer);
zinnia_result_t* zinnia_recognizer_classify(
    zinnia_recognizer_t* recognizer,
    const zinnia_character_t* character,
    size_t nbest);

const char* zinnia_result_value(zinnia_result_t* result, size_t index);
float zinnia_result_score(zinnia_result_t* result, size_t index);
size_t zinnia_result_size(zinnia_result_t* result);
void zinnia_result_destroy(zinnia_result_t* result);
}

struct RimeTraits {
  int data_size;
  const char* shared_data_dir;
  const char* user_data_dir;
  const char* distribution_name;
  const char* distribution_code_name;
  const char* distribution_version;
  const char* app_name;
  const char** modules;
  int min_log_level;
  const char* log_dir;
  const char* prebuilt_data_dir;
  const char* staging_dir;
};

struct RimeComposition {
  int length;
  int cursor_pos;
  int sel_start;
  int sel_end;
  char* preedit;
};

struct RimeCandidate {
  char* text;
  char* comment;
  void* reserved;
};

struct RimeMenu {
  int page_size;
  int page_no;
  Bool is_last_page;
  int highlighted_candidate_index;
  int num_candidates;
  RimeCandidate* candidates;
  char* select_keys;
};

struct RimeContext {
  int data_size;
  RimeComposition composition;
  RimeMenu menu;
  char* commit_text_preview;
  char** select_labels;
};

struct RimeCandidateListIterator {
  void* ptr;
  int index;
  RimeCandidate candidate;
};

using RimeSetupFn = void (*)(RimeTraits*);
using RimeInitializeFn = void (*)(RimeTraits*);
using RimeFinalizeFn = void (*)();
using RimeCreateSessionFn = RimeSessionId (*)();
using RimeDestroySessionFn = Bool (*)(RimeSessionId);
using RimeSelectSchemaFn = Bool (*)(RimeSessionId, const char*);
using RimeSetInputFn = Bool (*)(RimeSessionId, const char*);
using RimeClearCompositionFn = void (*)(RimeSessionId);
using RimeGetContextFn = Bool (*)(RimeSessionId, RimeContext*);
using RimeFreeContextFn = Bool (*)(RimeContext*);
using RimeStartMaintenanceFn = Bool (*)(Bool);
using RimeJoinMaintenanceThreadFn = void (*)();
using RimeCandidateListBeginFn =
    Bool (*)(RimeSessionId, RimeCandidateListIterator*);
using RimeCandidateListNextFn = Bool (*)(RimeCandidateListIterator*);
using RimeCandidateListEndFn = void (*)(RimeCandidateListIterator*);

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                       0, nullptr, nullptr);
  if (size <= 0) {
    return "";
  }
  std::string result(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size,
                      nullptr, nullptr);
  return result;
}

std::wstring ExeDir() {
  std::wstring buffer(MAX_PATH, L'\0');
  DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                    static_cast<DWORD>(buffer.size()));
  while (length == buffer.size()) {
    buffer.resize(buffer.size() * 2);
    length = GetModuleFileNameW(nullptr, buffer.data(),
                                static_cast<DWORD>(buffer.size()));
  }
  buffer.resize(length);
  return std::filesystem::path(buffer).parent_path().wstring();
}

std::wstring AppDataDir() {
  wchar_t* app_data = nullptr;
  size_t len = 0;
  if (_wdupenv_s(&app_data, &len, L"APPDATA") != 0 || !app_data) {
    return ExeDir();
  }
  std::wstring result(app_data);
  free(app_data);
  return result;
}

std::string StringArg(const EncodableMap& map,
                      const char* key,
                      const std::string& fallback = "") {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return fallback;
}

int IntArg(const EncodableMap& map, const char* key, int fallback = 0) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto value = std::get_if<int>(&it->second)) {
    return *value;
  }
  if (const auto value64 = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*value64);
  }
  return fallback;
}

double DoubleValue(const EncodableValue& value, double fallback = 0.0) {
  if (const auto number = std::get_if<double>(&value)) {
    return *number;
  }
  if (const auto number = std::get_if<int>(&value)) {
    return static_cast<double>(*number);
  }
  if (const auto number = std::get_if<int64_t>(&value)) {
    return static_cast<double>(*number);
  }
  return fallback;
}

std::string LastErrorText(const std::string& prefix) {
  std::ostringstream stream;
  stream << prefix << " (GetLastError=" << GetLastError() << ")";
  return stream.str();
}

std::string EscapeJson(const std::string& value) {
  std::ostringstream stream;
  for (const char ch : value) {
    switch (ch) {
      case '\\':
        stream << "\\\\";
        break;
      case '"':
        stream << "\\\"";
        break;
      case '\n':
        stream << "\\n";
        break;
      case '\r':
        stream << "\\r";
        break;
      case '\t':
        stream << "\\t";
        break;
      default:
        stream << ch;
        break;
    }
  }
  return stream.str();
}

class RimeRuntime {
 public:
  RimeRuntime() = default;
  ~RimeRuntime() { Shutdown(); }

  bool EnsureLoaded(std::string* error) {
    if (loaded_) {
      return true;
    }

    runtime_dir_ =
        std::filesystem::path(ExeDir()) / L"ime" / L"rime" / L"windows";
    const auto dll_path = runtime_dir_ / L"rime.dll";
    library_ = LoadLibraryW(dll_path.c_str());
    if (!library_) {
      if (error) {
        *error = LastErrorText("Unable to load bundled Rime runtime: " +
                               WideToUtf8(dll_path.wstring()));
      }
      return false;
    }

    setup_ = Symbol<RimeSetupFn>("RimeSetup");
    initialize_ = Symbol<RimeInitializeFn>("RimeInitialize");
    finalize_ = Symbol<RimeFinalizeFn>("RimeFinalize");
    create_session_ = Symbol<RimeCreateSessionFn>("RimeCreateSession");
    destroy_session_ = Symbol<RimeDestroySessionFn>("RimeDestroySession");
    select_schema_ = Symbol<RimeSelectSchemaFn>("RimeSelectSchema");
    set_input_ = Symbol<RimeSetInputFn>("RimeSetInput");
    clear_composition_ =
        Symbol<RimeClearCompositionFn>("RimeClearComposition");
    get_context_ = Symbol<RimeGetContextFn>("RimeGetContext");
    free_context_ = Symbol<RimeFreeContextFn>("RimeFreeContext");
    start_maintenance_ =
        Symbol<RimeStartMaintenanceFn>("RimeStartMaintenance");
    join_maintenance_thread_ =
        Symbol<RimeJoinMaintenanceThreadFn>("RimeJoinMaintenanceThread");
    candidate_list_begin_ =
        Symbol<RimeCandidateListBeginFn>("RimeCandidateListBegin");
    candidate_list_next_ =
        Symbol<RimeCandidateListNextFn>("RimeCandidateListNext");
    candidate_list_end_ = Symbol<RimeCandidateListEndFn>("RimeCandidateListEnd");

    if (!setup_ || !initialize_ || !finalize_ || !create_session_ ||
        !destroy_session_ || !select_schema_ || !set_input_ ||
        !clear_composition_ || !get_context_ || !free_context_ ||
        !start_maintenance_ || !join_maintenance_thread_ ||
        !candidate_list_begin_ || !candidate_list_next_ || !candidate_list_end_) {
      if (error) {
        *error = "Bundled rime.dll is missing required C API exports";
      }
      return false;
    }

    user_dir_ = std::filesystem::path(AppDataDir()) / L"Kirakara" / L"Rime";
    std::filesystem::create_directories(user_dir_);
    std::filesystem::create_directories(user_dir_ / L"build");

    shared_dir_utf8_ = WideToUtf8((runtime_dir_ / L"data").wstring());
    user_dir_utf8_ = WideToUtf8(user_dir_.wstring());
    prebuilt_dir_utf8_ = WideToUtf8((runtime_dir_ / L"build").wstring());
    staging_dir_utf8_ = WideToUtf8((user_dir_ / L"build").wstring());
    log_dir_utf8_ = WideToUtf8(user_dir_.wstring());

    RimeTraits traits = {};
    traits.data_size = sizeof(RimeTraits) - sizeof(traits.data_size);
    traits.shared_data_dir = shared_dir_utf8_.c_str();
    traits.user_data_dir = user_dir_utf8_.c_str();
    traits.distribution_name = "Kirakara";
    traits.distribution_code_name = "kirakara";
    traits.distribution_version = "0.1";
    traits.app_name = "rime.kirakara";
    traits.min_log_level = 2;
    traits.log_dir = log_dir_utf8_.c_str();
    traits.prebuilt_data_dir = prebuilt_dir_utf8_.c_str();
    traits.staging_dir = staging_dir_utf8_.c_str();

    setup_(&traits);
    initialize_(nullptr);
    if (start_maintenance_(1)) {
      join_maintenance_thread_();
    }
    loaded_ = true;
    return true;
  }

  EncodableValue Activate(const std::string& session_key,
                          const std::string& schema_id) {
    std::string error;
    if (!EnsureLoaded(&error)) {
      return ErrorValue(error);
    }

    auto& session = sessions_[session_key];
    if (session == 0) {
      session = create_session_();
    }
    if (session == 0) {
      return ErrorValue("RimeCreateSession returned 0");
    }
    if (!select_schema_(session, schema_id.c_str())) {
      return ErrorValue("RimeSelectSchema failed: " + schema_id);
    }
    return EncodableValue(EncodableMap{
        {EncodableValue("ok"), EncodableValue(true)},
        {EncodableValue("engine"), EncodableValue("rime")},
        {EncodableValue("schema"), EncodableValue(schema_id)},
        {EncodableValue("runtimeDir"), EncodableValue(WideToUtf8(runtime_dir_.wstring()))},
    });
  }

  EncodableValue Compose(const std::string& session_key,
                         const std::string& raw_input,
                         int page_index,
                         int page_size) {
    const auto activated = Activate(session_key, "luna_pinyin_simp");
    if (IsError(activated)) {
      return activated;
    }

    const auto session = sessions_[session_key];
    clear_composition_(session);
    if (!raw_input.empty() && !set_input_(session, raw_input.c_str())) {
      return ErrorValue("RimeSetInput failed: " + raw_input);
    }

    RimeContext context = {};
    context.data_size = sizeof(RimeContext) - sizeof(context.data_size);
    std::string preedit = raw_input;
    bool is_last_page = true;
    if (get_context_(session, &context)) {
      if (context.composition.preedit) {
        preedit = context.composition.preedit;
      }
      is_last_page = context.menu.is_last_page != 0;
      free_context_(&context);
    }

    EncodableList candidates;
    RimeCandidateListIterator iterator = {};
    const int start = page_index * page_size;
    const int end = start + page_size;
    int index = 0;
    bool has_next = false;
    if (candidate_list_begin_(session, &iterator)) {
      while (candidate_list_next_(&iterator)) {
        if (index >= start && index < end) {
          const std::string text = iterator.candidate.text
                                       ? std::string(iterator.candidate.text)
                                       : std::string();
          if (text.empty()) {
            index += 1;
            continue;
          }
          if (!HasCandidate(candidates, text)) {
            candidates.push_back(EncodableValue(EncodableMap{
                {EncodableValue("text"), EncodableValue(text)},
                {EncodableValue("annotation"),
                 EncodableValue(iterator.candidate.comment
                                    ? std::string(iterator.candidate.comment)
                                    : std::string())},
            }));
          }
        } else if (index >= end) {
          has_next = true;
          break;
        }
        index += 1;
      }
      candidate_list_end_(&iterator);
    }

    return EncodableValue(EncodableMap{
        {EncodableValue("ok"), EncodableValue(true)},
        {EncodableValue("rawInput"), EncodableValue(raw_input)},
        {EncodableValue("preedit"), EncodableValue(preedit)},
        {EncodableValue("pageIndex"), EncodableValue(page_index)},
        {EncodableValue("hasPreviousPage"), EncodableValue(page_index > 0)},
        {EncodableValue("hasNextPage"),
         EncodableValue(has_next || !is_last_page)},
        {EncodableValue("candidates"), EncodableValue(candidates)},
    });
  }

  EncodableValue Clear(const std::string& session_key) {
    std::string error;
    if (!EnsureLoaded(&error)) {
      return ErrorValue(error);
    }
    const auto it = sessions_.find(session_key);
    if (it != sessions_.end() && it->second != 0) {
      clear_composition_(it->second);
    }
    return EncodableValue(EncodableMap{
        {EncodableValue("ok"), EncodableValue(true)},
        {EncodableValue("rawInput"), EncodableValue("")},
        {EncodableValue("preedit"), EncodableValue("")},
        {EncodableValue("pageIndex"), EncodableValue(0)},
        {EncodableValue("hasPreviousPage"), EncodableValue(false)},
        {EncodableValue("hasNextPage"), EncodableValue(false)},
        {EncodableValue("candidates"), EncodableValue(EncodableList{})},
    });
  }

  bool IsErrorValue(const EncodableValue& value) const { return IsError(value); }

  void Deactivate(const std::string& session_key) {
    const auto it = sessions_.find(session_key);
    if (it == sessions_.end()) {
      return;
    }
    if (destroy_session_ && it->second != 0) {
      destroy_session_(it->second);
    }
    sessions_.erase(it);
  }

 private:
  static bool HasCandidate(const EncodableList& candidates,
                           const std::string& text) {
    for (const auto& value : candidates) {
      const auto* map = std::get_if<EncodableMap>(&value);
      if (!map) {
        continue;
      }
      const auto it = map->find(EncodableValue("text"));
      if (it == map->end()) {
        continue;
      }
      const auto* existing = std::get_if<std::string>(&it->second);
      if (existing && *existing == text) {
        return true;
      }
    }
    return false;
  }

  template <typename T>
  T Symbol(const char* name) {
    return reinterpret_cast<T>(GetProcAddress(library_, name));
  }

  static EncodableValue ErrorValue(const std::string& message) {
    return EncodableValue(EncodableMap{
        {EncodableValue("ok"), EncodableValue(false)},
        {EncodableValue("error"), EncodableValue(message)},
    });
  }

  static bool IsError(const EncodableValue& value) {
    if (const auto map = std::get_if<EncodableMap>(&value)) {
      const auto it = map->find(EncodableValue("ok"));
      if (it != map->end()) {
        if (const auto ok = std::get_if<bool>(&it->second)) {
          return !*ok;
        }
      }
    }
    return false;
  }

  void Shutdown() {
    for (const auto& item : sessions_) {
      if (destroy_session_ && item.second != 0) {
        destroy_session_(item.second);
      }
    }
    sessions_.clear();
    if (loaded_ && finalize_) {
      finalize_();
    }
    if (library_) {
      FreeLibrary(library_);
      library_ = nullptr;
    }
    loaded_ = false;
  }

  bool loaded_ = false;
  HMODULE library_ = nullptr;
  std::filesystem::path runtime_dir_;
  std::filesystem::path user_dir_;
  std::string shared_dir_utf8_;
  std::string user_dir_utf8_;
  std::string prebuilt_dir_utf8_;
  std::string staging_dir_utf8_;
  std::string log_dir_utf8_;
  std::unordered_map<std::string, RimeSessionId> sessions_;

  RimeSetupFn setup_ = nullptr;
  RimeInitializeFn initialize_ = nullptr;
  RimeFinalizeFn finalize_ = nullptr;
  RimeCreateSessionFn create_session_ = nullptr;
  RimeDestroySessionFn destroy_session_ = nullptr;
  RimeSelectSchemaFn select_schema_ = nullptr;
  RimeSetInputFn set_input_ = nullptr;
  RimeClearCompositionFn clear_composition_ = nullptr;
  RimeGetContextFn get_context_ = nullptr;
  RimeFreeContextFn free_context_ = nullptr;
  RimeStartMaintenanceFn start_maintenance_ = nullptr;
  RimeJoinMaintenanceThreadFn join_maintenance_thread_ = nullptr;
  RimeCandidateListBeginFn candidate_list_begin_ = nullptr;
  RimeCandidateListNextFn candidate_list_next_ = nullptr;
  RimeCandidateListEndFn candidate_list_end_ = nullptr;
};

struct StrokePoint {
  double x = 0.0;
  double y = 0.0;
};

struct ZinniaCandidate {
  std::string text;
  std::string annotation;
  double score = 0.0;
};

class ZinniaRuntime {
 public:
  ZinniaRuntime() = default;
  ~ZinniaRuntime() { DestroyRecognizers(); }

  bool EnsureLoaded(std::string* error) {
    if (loaded_) {
      return true;
    }

    runtime_dir_ =
        std::filesystem::path(ExeDir()) / L"ime" / L"zinnia" / L"windows";
    const auto model_dir = runtime_dir_ / L"models";
    const auto ja_model = model_dir / L"handwriting-ja.model";
    const auto zh_model = model_dir / L"handwriting-zh_CN.model";

    recognizer_ja_ = zinnia_recognizer_new();
    recognizer_zh_ = zinnia_recognizer_new();
    if (!recognizer_ja_ || !recognizer_zh_) {
      if (error) {
        *error = "Unable to create Zinnia recognizers";
      }
      DestroyRecognizers();
      return false;
    }

    if (!ReadModelFile(ja_model, "Japanese", &ja_model_data_, error)) {
      DestroyRecognizers();
      return false;
    }
    if (!ReadModelFile(zh_model, "Chinese", &zh_model_data_, error)) {
      DestroyRecognizers();
      return false;
    }

    if (!zinnia_recognizer_open_from_ptr(
            recognizer_ja_, ja_model_data_.data(), ja_model_data_.size())) {
      if (error) {
        *error = "Unable to open bundled Zinnia Japanese model: " +
                 RecognizerError(recognizer_ja_);
      }
      DestroyRecognizers();
      return false;
    }
    if (!zinnia_recognizer_open_from_ptr(
            recognizer_zh_, zh_model_data_.data(), zh_model_data_.size())) {
      if (error) {
        *error = "Unable to open bundled Zinnia Chinese model: " +
                 RecognizerError(recognizer_zh_);
      }
      DestroyRecognizers();
      return false;
    }

    loaded_ = true;
    return true;
  }

  EncodableValue Activate() {
    std::string error;
    if (!EnsureLoaded(&error)) {
      return ErrorValue(error);
    }
    return EncodableValue(EncodableMap{
        {EncodableValue("ok"), EncodableValue(true)},
        {EncodableValue("engine"), EncodableValue("zinnia")},
        {EncodableValue("runtimeDir"),
         EncodableValue(WideToUtf8(runtime_dir_.wstring()))},
    });
  }

  EncodableValue Recognize(const EncodableMap& args) {
    std::string error;
    if (!EnsureLoaded(&error)) {
      return ErrorValue(error);
    }

    const auto strokes = ParseStrokes(args);
    const int nbest = IntArg(args, "nbest", 10);
    if (strokes.empty()) {
      return CandidateValue({});
    }
    return RecognizeStrokes(strokes, nbest);
  }

  EncodableValue RecognizeStrokes(
      const std::vector<std::vector<StrokePoint>>& strokes,
      int nbest) {
    std::string error;
    if (!EnsureLoaded(&error)) {
      return ErrorValue(error);
    }

    std::unique_ptr<zinnia_character_t, decltype(&zinnia_character_destroy)>
        character(zinnia_character_new(), zinnia_character_destroy);
    if (!character) {
      return ErrorValue("Unable to create Zinnia character");
    }
    BuildCharacter(strokes, character.get());

    std::vector<ZinniaCandidate> candidates;
    AppendCandidates(recognizer_ja_, character.get(), "手写 · 日本語", nbest,
                     &candidates);
    AppendCandidates(recognizer_zh_, character.get(), "手写 · 中文", nbest,
                     &candidates);

    std::sort(candidates.begin(), candidates.end(),
              [](const ZinniaCandidate& left, const ZinniaCandidate& right) {
                return left.score > right.score;
              });
    if (candidates.size() > static_cast<size_t>(nbest)) {
      candidates.resize(static_cast<size_t>(nbest));
    }
    return CandidateValue(candidates);
  }

  bool IsErrorValue(const EncodableValue& value) const { return IsError(value); }

 private:
  static bool ReadModelFile(const std::filesystem::path& path,
                            const char* model_name,
                            std::vector<char>* data,
                            std::string* error) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) {
      if (error) {
        *error = std::string("Unable to read bundled Zinnia ") + model_name +
                 " model";
      }
      return false;
    }

    const std::streamoff size = stream.tellg();
    if (size <= 0 ||
        static_cast<uintmax_t>(size) >
            static_cast<uintmax_t>(std::numeric_limits<size_t>::max())) {
      if (error) {
        *error = std::string("Bundled Zinnia ") + model_name +
                 " model is empty or too large";
      }
      return false;
    }

    data->resize(static_cast<size_t>(size));
    stream.seekg(0, std::ios::beg);
    if (!stream.read(data->data(), size)) {
      data->clear();
      if (error) {
        *error = std::string("Unable to read bundled Zinnia ") + model_name +
                 " model data";
      }
      return false;
    }
    return true;
  }

  static std::vector<std::vector<StrokePoint>> ParseStrokes(
      const EncodableMap& args) {
    std::vector<std::vector<StrokePoint>> strokes;
    const auto it = args.find(EncodableValue("strokes"));
    if (it == args.end()) {
      return strokes;
    }
    const auto* stroke_list = std::get_if<EncodableList>(&it->second);
    if (!stroke_list) {
      return strokes;
    }
    for (const auto& stroke_value : *stroke_list) {
      const auto* point_list = std::get_if<EncodableList>(&stroke_value);
      if (!point_list) {
        continue;
      }
      std::vector<StrokePoint> stroke;
      for (const auto& point_value : *point_list) {
        const auto* point_map = std::get_if<EncodableMap>(&point_value);
        if (!point_map) {
          continue;
        }
        const auto x_it = point_map->find(EncodableValue("x"));
        const auto y_it = point_map->find(EncodableValue("y"));
        if (x_it == point_map->end() || y_it == point_map->end()) {
          continue;
        }
        stroke.push_back(StrokePoint{
            DoubleValue(x_it->second),
            DoubleValue(y_it->second),
        });
      }
      if (!stroke.empty()) {
        strokes.push_back(std::move(stroke));
      }
    }
    return strokes;
  }

  static void BuildCharacter(
      const std::vector<std::vector<StrokePoint>>& strokes,
      zinnia_character_t* character) {
    double min_x = std::numeric_limits<double>::max();
    double min_y = std::numeric_limits<double>::max();
    double max_x = std::numeric_limits<double>::lowest();
    double max_y = std::numeric_limits<double>::lowest();
    for (const auto& stroke : strokes) {
      for (const auto& point : stroke) {
        min_x = std::min(min_x, point.x);
        min_y = std::min(min_y, point.y);
        max_x = std::max(max_x, point.x);
        max_y = std::max(max_y, point.y);
      }
    }

    constexpr double kCanvas = 1000.0;
    constexpr double kMargin = 50.0;
    const double raw_width = std::max(1.0, max_x - min_x);
    const double raw_height = std::max(1.0, max_y - min_y);
    const double scale = (kCanvas - kMargin * 2.0) /
                         std::max(raw_width, raw_height);
    const double x_offset = (kCanvas - raw_width * scale) / 2.0;
    const double y_offset = (kCanvas - raw_height * scale) / 2.0;

    zinnia_character_clear(character);
    zinnia_character_set_width(character, static_cast<size_t>(kCanvas));
    zinnia_character_set_height(character, static_cast<size_t>(kCanvas));
    for (size_t stroke_index = 0; stroke_index < strokes.size();
         ++stroke_index) {
      for (const auto& point : strokes[stroke_index]) {
        const auto x = ClampCanvas((point.x - min_x) * scale + x_offset);
        const auto y = ClampCanvas((point.y - min_y) * scale + y_offset);
        zinnia_character_add(character, stroke_index, x, y);
      }
    }
  }

  static int ClampCanvas(double value) {
    const auto rounded = static_cast<int>(std::lround(value));
    return std::clamp(rounded, 0, 1000);
  }

  static void AppendCandidates(zinnia_recognizer_t* recognizer,
                               const zinnia_character_t* character,
                               const std::string& annotation,
                               int nbest,
                               std::vector<ZinniaCandidate>* candidates) {
    std::unique_ptr<zinnia_result_t, decltype(&zinnia_result_destroy)> result(
        zinnia_recognizer_classify(
            recognizer, character, static_cast<size_t>(nbest)),
        zinnia_result_destroy);
    if (!result) {
      return;
    }
    for (size_t index = 0; index < zinnia_result_size(result.get());
         ++index) {
      const char* value = zinnia_result_value(result.get(), index);
      if (!value || value[0] == '\0') {
        continue;
      }
      const std::string text(value);
      if (HasCandidate(*candidates, text)) {
        continue;
      }
      candidates->push_back(ZinniaCandidate{
          text,
          annotation,
          static_cast<double>(zinnia_result_score(result.get(), index)),
      });
    }
  }

  void DestroyRecognizers() {
    if (recognizer_ja_) {
      zinnia_recognizer_destroy(recognizer_ja_);
      recognizer_ja_ = nullptr;
    }
    if (recognizer_zh_) {
      zinnia_recognizer_destroy(recognizer_zh_);
      recognizer_zh_ = nullptr;
    }
    ja_model_data_.clear();
    zh_model_data_.clear();
    loaded_ = false;
  }

  static std::string RecognizerError(zinnia_recognizer_t* recognizer) {
    const char* error = recognizer ? zinnia_recognizer_strerror(recognizer)
                                   : nullptr;
    return error ? std::string(error) : std::string("unknown error");
  }

  static bool HasCandidate(const std::vector<ZinniaCandidate>& candidates,
                           const std::string& text) {
    return std::any_of(
        candidates.begin(), candidates.end(),
        [&text](const ZinniaCandidate& candidate) {
          return candidate.text == text;
        });
  }

  static EncodableValue CandidateValue(
      const std::vector<ZinniaCandidate>& candidates) {
    EncodableList encoded_candidates;
    for (const auto& candidate : candidates) {
      encoded_candidates.push_back(EncodableValue(EncodableMap{
          {EncodableValue("text"), EncodableValue(candidate.text)},
          {EncodableValue("annotation"), EncodableValue(candidate.annotation)},
          {EncodableValue("score"), EncodableValue(candidate.score)},
      }));
    }
    return EncodableValue(EncodableMap{
        {EncodableValue("ok"), EncodableValue(true)},
        {EncodableValue("candidates"), EncodableValue(encoded_candidates)},
    });
  }

  static EncodableValue ErrorValue(const std::string& message) {
    return EncodableValue(EncodableMap{
        {EncodableValue("ok"), EncodableValue(false)},
        {EncodableValue("error"), EncodableValue(message)},
    });
  }

  static bool IsError(const EncodableValue& value) {
    if (const auto map = std::get_if<EncodableMap>(&value)) {
      const auto it = map->find(EncodableValue("ok"));
      if (it != map->end()) {
        if (const auto ok = std::get_if<bool>(&it->second)) {
          return !*ok;
        }
      }
    }
    return false;
  }

  bool loaded_ = false;
  std::filesystem::path runtime_dir_;
  std::vector<char> ja_model_data_;
  std::vector<char> zh_model_data_;
  zinnia_recognizer_t* recognizer_ja_ = nullptr;
  zinnia_recognizer_t* recognizer_zh_ = nullptr;
};

std::unique_ptr<RimeRuntime> g_rime;
std::unique_ptr<ZinniaRuntime> g_zinnia;

std::vector<std::string> CandidateTexts(const EncodableValue& value) {
  std::vector<std::string> texts;
  const auto* map = std::get_if<EncodableMap>(&value);
  if (!map) {
    return texts;
  }
  const auto it = map->find(EncodableValue("candidates"));
  if (it == map->end()) {
    return texts;
  }
  const auto* list = std::get_if<EncodableList>(&it->second);
  if (!list) {
    return texts;
  }
  for (const auto& item : *list) {
    const auto* candidate = std::get_if<EncodableMap>(&item);
    if (!candidate) {
      continue;
    }
    const auto text_it = candidate->find(EncodableValue("text"));
    if (text_it == candidate->end()) {
      continue;
    }
    if (const auto* text = std::get_if<std::string>(&text_it->second)) {
      texts.push_back(*text);
    }
  }
  return texts;
}

std::string CandidateJsonArray(const std::vector<std::string>& candidates) {
  std::ostringstream stream;
  stream << "[";
  for (size_t i = 0; i < candidates.size(); ++i) {
    if (i > 0) {
      stream << ",";
    }
    stream << "\"" << EscapeJson(candidates[i]) << "\"";
  }
  stream << "]";
  return stream.str();
}

const EncodableMap* ArgsMap(const MethodCall& call) {
  return std::get_if<EncodableMap>(call.arguments());
}

void HandleMethodCall(const MethodCall& call,
                      std::unique_ptr<MethodResult> result) {
  const auto* args = ArgsMap(call);
  if (!args) {
    result->Error("bad_args", "Expected map arguments");
    return;
  }

  if (call.method_name().rfind("zinnia.", 0) == 0) {
    if (!g_zinnia) {
      g_zinnia = std::make_unique<ZinniaRuntime>();
    }
    if (call.method_name() == "zinnia.activate") {
      result->Success(g_zinnia->Activate());
      return;
    }
    if (call.method_name() == "zinnia.deactivate") {
      result->Success(EncodableValue(true));
      return;
    }
    if (call.method_name() == "zinnia.recognize") {
      result->Success(g_zinnia->Recognize(*args));
      return;
    }
    if (call.method_name() == "zinnia.clear") {
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("ok"), EncodableValue(true)},
          {EncodableValue("candidates"), EncodableValue(EncodableList{})},
      }));
      return;
    }
  }

  if (!g_rime) {
    g_rime = std::make_unique<RimeRuntime>();
  }

  const auto session_id = StringArg(*args, "sessionId", "kirakara-rime");
  if (call.method_name() == "rime.activate") {
    const auto schema = StringArg(*args, "schema", "luna_pinyin_simp");
    result->Success(g_rime->Activate(session_id, schema));
    return;
  }
  if (call.method_name() == "rime.deactivate") {
    g_rime->Deactivate(session_id);
    result->Success(EncodableValue(true));
    return;
  }
  if (call.method_name() == "rime.compose") {
    const auto raw_input = StringArg(*args, "rawInput");
    const auto page_index = IntArg(*args, "pageIndex", 0);
    const auto page_size = IntArg(*args, "pageSize", 25);
    result->Success(
        g_rime->Compose(session_id, raw_input, page_index, page_size));
    return;
  }
  if (call.method_name() == "rime.clear") {
    result->Success(g_rime->Clear(session_id));
    return;
  }

  result->NotImplemented();
}

}  // namespace

void RegisterImeBridge(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "kirakara/ime",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const MethodCall& call, std::unique_ptr<MethodResult> result) {
        HandleMethodCall(call, std::move(result));
      });
  static std::unique_ptr<flutter::MethodChannel<EncodableValue>> ime_channel;
  ime_channel = std::move(channel);
}

bool RunImeBridgeSelfTest(const std::wstring& output_path) {
  RimeRuntime runtime;
  const auto activate = runtime.Activate("probe", "luna_pinyin_simp");
  const auto cao = runtime.Compose("probe", "cao", 0, 8);
  const auto cao_candidates = CandidateTexts(cao);
  const auto qilixiang = runtime.Compose("probe", "qilixiang", 0, 8);
  const auto qilixiang_candidates = CandidateTexts(qilixiang);

  const bool has_cao = std::find(cao_candidates.begin(), cao_candidates.end(),
                                 "\xE8\x8D\x89") != cao_candidates.end() ||
                       std::find(cao_candidates.begin(), cao_candidates.end(),
                                 "\xE6\x93\x8D") != cao_candidates.end() ||
                       std::find(cao_candidates.begin(), cao_candidates.end(),
                                 "\xE6\x9B\xB9") != cao_candidates.end();

  ZinniaRuntime zinnia_runtime;
  const auto zinnia_activate = zinnia_runtime.Activate();
  const std::vector<std::vector<StrokePoint>> sample_strokes = {
      {{51, 29}, {117, 41}},
      {{99, 65}, {219, 77}},
      {{27, 131}, {261, 131}},
      {{129, 17}, {57, 203}},
      {{111, 71}, {219, 173}},
      {{81, 161}, {93, 281}},
      {{99, 167}, {207, 167}, {189, 245}},
      {{99, 227}, {189, 227}},
      {{111, 257}, {189, 245}},
  };
  const auto zinnia = zinnia_runtime.RecognizeStrokes(sample_strokes, 8);
  const auto zinnia_candidates = CandidateTexts(zinnia);

  const bool rime_ok = has_cao && !runtime.IsErrorValue(activate);
  const bool zinnia_ok = !zinnia_runtime.IsErrorValue(zinnia_activate) &&
                         !zinnia_runtime.IsErrorValue(zinnia) &&
                         !zinnia_candidates.empty();
  const bool ok = rime_ok && zinnia_ok;

  std::ofstream output(output_path, std::ios::binary);
  if (!output) {
    return false;
  }
  output << "{";
  output << "\"ok\":" << (ok ? "true" : "false") << ",";
  output << "\"rime\":{";
  output << "\"ok\":" << (rime_ok ? "true" : "false") << ",";
  output << "\"cao\":" << CandidateJsonArray(cao_candidates) << ",";
  output << "\"qilixiang\":" << CandidateJsonArray(qilixiang_candidates)
         << ",";
  output << "\"activated\":"
         << (runtime.IsErrorValue(activate) ? "false" : "true");
  output << "},";
  output << "\"zinnia\":{";
  output << "\"ok\":" << (zinnia_ok ? "true" : "false") << ",";
  output << "\"sample\":" << CandidateJsonArray(zinnia_candidates) << ",";
  output << "\"activated\":"
         << (zinnia_runtime.IsErrorValue(zinnia_activate) ? "false" : "true");
  output << "}";
  output << "}";
  return ok;
}
