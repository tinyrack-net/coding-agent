#ifndef RUNNER_AGENT_NAVIGATION_H_
#define RUNNER_AGENT_NAVIGATION_H_

#include <windows.h>

#include <optional>
#include <string>
#include <vector>

inline constexpr wchar_t kCodingAgentWindowClassName[] =
    L"FLUTTER_RUNNER_WIN32_WINDOW";
inline constexpr wchar_t kCodingAgentWindowPropertyName[] =
    L"Tinyrack.CodingAgent";
inline constexpr wchar_t kCodingAgentInstanceMutexName[] =
    L"Local\\Tinyrack.CodingAgent";
inline constexpr ULONG_PTR kCodingAgentCopyDataId = 0x54434147;
inline constexpr size_t kMaximumAgentDeepLinkBytes = 32 * 1024;

std::optional<std::string>
FindAgentDeepLinkArgument(const std::vector<std::string> &arguments);

class NativeAgentNavigationInbox {
public:
  void Push(std::string uri);
  void SetReady(bool ready);
  bool ready() const;
  std::optional<std::string> TakePending();

private:
  bool ready_ = false;
  std::optional<std::string> pending_;
};

// Relays |uri| to an existing Tinyrack window. It retries while the primary
// process is still creating its window and returns true only after the target
// acknowledges WM_COPYDATA.
bool RelayAgentDeepLinkToExistingWindow(const std::string &uri);

// Decodes a trusted coding-agent WM_COPYDATA payload. Returns nullopt for
// foreign, oversized, unterminated, or malformed data.
std::optional<std::string>
DecodeAgentDeepLinkCopyData(const COPYDATASTRUCT *copy_data);

#endif // RUNNER_AGENT_NAVIGATION_H_
