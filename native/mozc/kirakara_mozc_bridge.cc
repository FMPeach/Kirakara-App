// Copyright 2026 FMPeach.
//
// This bridge links against Mozc as an app-owned runtime. It returns IME
// composition candidates only; catalog/song matching belongs to Kirakara's
// search layer.

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "base/init_mozc.h"
#include "composer/composer.h"
#include "composer/key_parser.h"
#include "engine/engine_factory.h"
#include "engine/engine_converter_interface.h"
#include "engine/engine_interface.h"
#include "protocol/candidate_window.pb.h"
#include "protocol/commands.pb.h"
#include "transliteration/transliteration.h"

namespace {

struct Candidate {
  std::string text;
  std::string annotation;
};

std::string EscapeJson(const std::string& value) {
  std::ostringstream out;
  for (const unsigned char ch : value) {
    switch (ch) {
      case '"':
        out << "\\\"";
        break;
      case '\\':
        out << "\\\\";
        break;
      case '\b':
        out << "\\b";
        break;
      case '\f':
        out << "\\f";
        break;
      case '\n':
        out << "\\n";
        break;
      case '\r':
        out << "\\r";
        break;
      case '\t':
        out << "\\t";
        break;
      default:
        if (ch < 0x20) {
          out << "\\u";
          constexpr char kHex[] = "0123456789abcdef";
          out << "00" << kHex[(ch >> 4) & 0x0f] << kHex[ch & 0x0f];
        } else {
          out << ch;
        }
        break;
    }
  }
  return out.str();
}

bool ContainsCandidate(const std::vector<Candidate>& candidates,
                       const std::string& text) {
  return std::any_of(candidates.begin(), candidates.end(),
                     [&text](const Candidate& candidate) {
                       return candidate.text == text;
                     });
}

std::string AnnotationText(const mozc::commands::Annotation& annotation) {
  if (annotation.has_description()) {
    return annotation.description();
  }
  if (annotation.has_suffix()) {
    return annotation.suffix();
  }
  if (annotation.has_prefix()) {
    return annotation.prefix();
  }
  return "";
}

std::string PreeditText(const mozc::commands::Output& output,
                        const std::string& fallback) {
  if (!output.has_preedit()) {
    return fallback;
  }

  std::string text;
  const mozc::commands::Preedit& preedit = output.preedit();
  for (int i = 0; i < preedit.segment_size(); ++i) {
    text += preedit.segment(i).value();
  }
  return text.empty() ? fallback : text;
}

void AddCandidate(std::vector<Candidate>* candidates, const std::string& text,
                  const std::string& annotation = "") {
  if (text.empty() || ContainsCandidate(*candidates, text)) {
    return;
  }
  candidates->push_back(Candidate{text, annotation});
}

std::vector<Candidate> CandidateList(const mozc::commands::Output& output,
                                     const std::string& preedit) {
  std::vector<Candidate> candidates;
  AddCandidate(&candidates, preedit);

  if (output.has_candidate_window()) {
    const mozc::commands::CandidateWindow& window = output.candidate_window();
    for (int i = 0; i < window.candidate_size(); ++i) {
      const auto& candidate = window.candidate(i);
      AddCandidate(&candidates, candidate.value(),
                   candidate.has_annotation()
                       ? AnnotationText(candidate.annotation())
                       : "");
    }
  }

  if (output.has_all_candidate_words()) {
    const mozc::commands::CandidateList& words = output.all_candidate_words();
    for (int i = 0; i < words.candidates_size(); ++i) {
      const auto& candidate = words.candidates(i);
      AddCandidate(&candidates, candidate.value(),
                   candidate.has_annotation()
                       ? AnnotationText(candidate.annotation())
                       : "");
    }
  }

  return candidates;
}

bool InsertAsciiKey(mozc::composer::Composer* composer, char key) {
  mozc::commands::KeyEvent key_event;
  const char normalized =
      static_cast<char>(std::tolower(static_cast<unsigned char>(key)));
  const std::string key_text(1, normalized);
  if (!mozc::KeyParser::ParseKey(key_text, &key_event)) {
    return false;
  }
  key_event.set_activated(true);
  key_event.set_mode(mozc::commands::HIRAGANA);
  return composer->InsertCharacterKeyEvent(key_event);
}

std::string ResultJson(const std::string& raw_input, const std::string& preedit,
                       const std::vector<Candidate>& all_candidates,
                       int page_index, int page_size, bool ok = true,
                       const std::string& error = "") {
  const int safe_page_size = std::max(page_size, 1);
  const int safe_page_index = std::max(page_index, 0);
  const size_t start =
      static_cast<size_t>(safe_page_index * safe_page_size);
  const size_t end =
      std::min(all_candidates.size(), start + static_cast<size_t>(safe_page_size));

  std::ostringstream out;
  out << "{\"ok\":" << (ok ? "true" : "false");
  if (!ok) {
    out << ",\"error\":\"" << EscapeJson(error) << "\"}";
    return out.str();
  }

  out << ",\"rawInput\":\"" << EscapeJson(raw_input) << "\"";
  out << ",\"preedit\":\"" << EscapeJson(preedit) << "\"";
  out << ",\"pageIndex\":" << safe_page_index;
  out << ",\"hasPreviousPage\":" << (safe_page_index > 0 ? "true" : "false");
  out << ",\"hasNextPage\":"
      << (end < all_candidates.size() ? "true" : "false");
  out << ",\"candidates\":[";
  for (size_t i = start; i < end; ++i) {
    if (i != start) {
      out << ",";
    }
    out << "{\"text\":\"" << EscapeJson(all_candidates[i].text) << "\"";
    if (!all_candidates[i].annotation.empty()) {
      out << ",\"annotation\":\"" << EscapeJson(all_candidates[i].annotation)
          << "\"";
    }
    out << "}";
  }
  out << "]}";
  return out.str();
}

std::string Compose(mozc::EngineInterface* engine, const std::string& raw_input,
                    int page_index, int page_size) {
  if (raw_input.empty()) {
    return ResultJson("", "", {}, page_index, page_size);
  }

  auto request = std::make_shared<mozc::commands::Request>();
  auto config = std::make_shared<mozc::config::Config>();
  auto table = std::make_shared<mozc::composer::Table>();
  table->InitializeWithRequestAndConfig(*request, *config);

  mozc::composer::Composer composer(table, request, config);
  composer.SetInputMode(mozc::transliteration::HIRAGANA);
  composer.SetOutputMode(mozc::transliteration::HIRAGANA);

  for (const char key : raw_input) {
    if (std::isalnum(static_cast<unsigned char>(key))) {
      InsertAsciiKey(&composer, key);
    }
  }

  auto converter = engine->CreateEngineConverter();
  mozc::commands::Output output;
  const bool converted = converter->Convert(composer);
  for (int i = 0; i < page_index; ++i) {
    converter->CandidateNextPage();
  }
  if (converted) {
    converter->SetCandidateListVisible(true);
    converter->PopOutput(composer, &output);
  } else {
    converter->FillPreedit(composer, output.mutable_preedit());
  }

  const std::string preedit = PreeditText(output, composer.GetStringForPreedit());
  std::vector<Candidate> candidates = CandidateList(output, preedit);
  return ResultJson(raw_input, preedit, candidates, page_index, page_size);
}

}  // namespace

int main(int argc, char** argv) {
  mozc::InitMozc(argv[0], &argc, &argv);

  if (argc < 2) {
    std::cout << ResultJson("", "", {}, 0, 8, false,
                            "missing bridge command")
              << std::endl;
    return 2;
  }

  const std::string command = argv[1];
  if (command == "clear" || command == "activate" ||
      command == "deactivate") {
    std::cout << ResultJson("", "", {}, 0, 8) << std::endl;
    return 0;
  }

  if (command != "compose") {
    std::cout << ResultJson("", "", {}, 0, 8, false,
                            "unknown bridge command")
              << std::endl;
    return 2;
  }

  const std::string raw_input = argc > 2 ? argv[2] : "";
  const int page_index = argc > 3 ? std::max(std::atoi(argv[3]), 0) : 0;
  const int page_size = argc > 4 ? std::max(std::atoi(argv[4]), 1) : 8;

  auto engine = mozc::EngineFactory::Create();
  if (!engine.ok()) {
    std::cout << ResultJson(raw_input, raw_input, {}, page_index, page_size,
                            false, "failed to create Mozc engine")
              << std::endl;
    return 1;
  }

  std::cout << Compose(engine->get(), raw_input, page_index, page_size)
            << std::endl;
  return 0;
}
