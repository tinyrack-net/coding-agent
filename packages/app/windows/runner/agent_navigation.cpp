#include "agent_navigation.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <thread>

namespace {

constexpr int kFindWindowAttempts = 50;
constexpr auto kFindWindowRetryDelay = std::chrono::milliseconds(100);
constexpr UINT kSendMessageTimeoutMs = 2000;

bool EqualsAsciiCaseInsensitive(char left, char right) {
  return std::tolower(static_cast<unsigned char>(left)) ==
         std::tolower(static_cast<unsigned char>(right));
}

bool StartsWithAsciiCaseInsensitive(const std::string &value,
                                    const std::string &prefix) {
  return value.size() >= prefix.size() &&
         std::equal(prefix.begin(), prefix.end(), value.begin(),
                    EqualsAsciiCaseInsensitive);
}

bool IsAgentDeepLinkCandidate(const std::string &value) {
  constexpr char kPrefix[] = "coding-agent://h/";
  if (!std::all_of(
          value.begin(), value.end(),
          [](unsigned char byte) { return byte >= 0x21 && byte <= 0x7e; }) ||
      !StartsWithAsciiCaseInsensitive(value, kPrefix) ||
      value.find_first_of("?#") != std::string::npos) {
    return false;
  }
  const size_t server_start = std::char_traits<char>::length(kPrefix);
  const size_t separator = value.find("/agent/", server_start);
  if (separator == std::string::npos || separator == server_start) {
    return false;
  }
  const size_t agent_start =
      separator + std::char_traits<char>::length("/agent/");
  if (agent_start >= value.size()) {
    return false;
  }
  return value.find('/', agent_start) == std::string::npos;
}

BOOL CALLBACK FindCodingAgentWindow(HWND window, LPARAM result_address) {
  if (GetPropW(window, kCodingAgentWindowPropertyName) == nullptr) {
    return TRUE;
  }
  *reinterpret_cast<HWND *>(result_address) = window;
  return FALSE;
}

HWND FindExistingWindow() {
  for (int attempt = 0; attempt < kFindWindowAttempts; ++attempt) {
    HWND window = nullptr;
    EnumWindows(FindCodingAgentWindow, reinterpret_cast<LPARAM>(&window));
    if (window != nullptr) {
      return window;
    }
    std::this_thread::sleep_for(kFindWindowRetryDelay);
  }
  return nullptr;
}

} // namespace

std::optional<std::string>
FindAgentDeepLinkArgument(const std::vector<std::string> &arguments) {
  for (const auto &argument : arguments) {
    if (IsAgentDeepLinkCandidate(argument)) {
      return argument;
    }
  }
  return std::nullopt;
}

void NativeAgentNavigationInbox::Push(std::string uri) {
  pending_ = std::move(uri);
}

void NativeAgentNavigationInbox::SetReady(bool ready) { ready_ = ready; }

bool NativeAgentNavigationInbox::ready() const { return ready_; }

std::optional<std::string> NativeAgentNavigationInbox::TakePending() {
  auto pending = std::move(pending_);
  pending_.reset();
  return pending;
}

bool RelayAgentDeepLinkToExistingWindow(const std::string &uri) {
  if (!IsAgentDeepLinkCandidate(uri) ||
      uri.size() + 1 > kMaximumAgentDeepLinkBytes) {
    return false;
  }
  HWND window = FindExistingWindow();
  if (window == nullptr) {
    return false;
  }

  DWORD primary_process_id = 0;
  GetWindowThreadProcessId(window, &primary_process_id);
  if (primary_process_id != 0) {
    AllowSetForegroundWindow(primary_process_id);
  }

  COPYDATASTRUCT copy_data{};
  copy_data.dwData = kCodingAgentCopyDataId;
  copy_data.cbData = static_cast<DWORD>(uri.size() + 1);
  copy_data.lpData = const_cast<char *>(uri.c_str());
  DWORD_PTR result = 0;
  const LRESULT delivered = SendMessageTimeoutW(
      window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&copy_data),
      SMTO_ABORTIFHUNG | SMTO_BLOCK, kSendMessageTimeoutMs, &result);
  return delivered != 0 && result == TRUE;
}

std::optional<std::string>
DecodeAgentDeepLinkCopyData(const COPYDATASTRUCT *copy_data) {
  if (copy_data == nullptr || copy_data->dwData != kCodingAgentCopyDataId ||
      copy_data->lpData == nullptr || copy_data->cbData == 0 ||
      copy_data->cbData > kMaximumAgentDeepLinkBytes) {
    return std::nullopt;
  }
  const auto *bytes = static_cast<const char *>(copy_data->lpData);
  if (bytes[copy_data->cbData - 1] != '\0') {
    return std::nullopt;
  }
  const std::string uri(bytes, copy_data->cbData - 1);
  return IsAgentDeepLinkCandidate(uri) ? std::optional(uri) : std::nullopt;
}
