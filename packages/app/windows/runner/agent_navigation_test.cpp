#include "agent_navigation.h"

#include <iostream>
#include <string>
#include <vector>

namespace {

std::optional<std::string> g_relayed_uri;

int Fail(const char *message) {
  std::cerr << message << std::endl;
  return 1;
}

LRESULT CALLBACK RelayWindowProc(HWND window, UINT message, WPARAM wparam,
                                 LPARAM lparam) {
  if (message == WM_COPYDATA) {
    g_relayed_uri = DecodeAgentDeepLinkCopyData(
        reinterpret_cast<const COPYDATASTRUCT *>(lparam));
    return g_relayed_uri.has_value() ? TRUE : FALSE;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

} // namespace

int main() {
  const auto target =
      FindAgentDeepLinkArgument({"coding_agent_app.exe", "--hidden",
                                 "coding-agent://h/server-1/agent/agent-2"});
  if (!target.has_value() ||
      target.value() != "coding-agent://h/server-1/agent/agent-2") {
    return Fail("valid agent link was not found");
  }
  const std::string embedded_null =
      std::string("coding-agent://h/server/agent/a") + '\0' + "b";
  if (FindAgentDeepLinkArgument(
          {"coding-agent://h/server/agent/agent?message=ignored"})
          .has_value() ||
      FindAgentDeepLinkArgument({"coding-agent://h/server/agent/agent/extra"})
          .has_value() ||
      FindAgentDeepLinkArgument({"coding-agent://h//agent/agent"})
          .has_value() ||
      FindAgentDeepLinkArgument({embedded_null}).has_value() ||
      FindAgentDeepLinkArgument({"coding-agent://h/server/agent/a\nb"})
          .has_value()) {
    return Fail("malformed agent link was accepted");
  }
  const auto encoded = FindAgentDeepLinkArgument(
      {"coding-agent://h/server%20one/agent/agent%2Ftwo"});
  if (!encoded.has_value()) {
    return Fail("percent-encoded opaque IDs were rejected");
  }

  NativeAgentNavigationInbox inbox;
  inbox.Push("coding-agent://h/server/agent/agent-1");
  inbox.Push("coding-agent://h/server/agent/agent-2");
  if (inbox.ready()) {
    return Fail("inbox started ready");
  }
  inbox.SetReady(true);
  const auto pending = inbox.TakePending();
  if (!pending.has_value() ||
      pending.value() != "coding-agent://h/server/agent/agent-2" ||
      inbox.TakePending().has_value()) {
    return Fail("inbox did not retain only the newest pending link");
  }

  std::string payload = "coding-agent://h/server/agent/agent";
  COPYDATASTRUCT copy_data{};
  copy_data.dwData = kCodingAgentCopyDataId;
  copy_data.cbData = static_cast<DWORD>(payload.size() + 1);
  copy_data.lpData = payload.data();
  if (DecodeAgentDeepLinkCopyData(&copy_data) != payload) {
    return Fail("valid WM_COPYDATA payload was not decoded");
  }
  copy_data.dwData = 0;
  if (DecodeAgentDeepLinkCopyData(&copy_data).has_value()) {
    return Fail("foreign WM_COPYDATA payload was accepted");
  }
  copy_data.dwData = kCodingAgentCopyDataId;
  copy_data.cbData = static_cast<DWORD>(payload.size());
  if (DecodeAgentDeepLinkCopyData(&copy_data).has_value()) {
    return Fail("unterminated WM_COPYDATA payload was accepted");
  }
  copy_data.cbData = static_cast<DWORD>(embedded_null.size() + 1);
  copy_data.lpData = const_cast<char *>(embedded_null.data());
  if (DecodeAgentDeepLinkCopyData(&copy_data).has_value()) {
    return Fail("embedded NUL WM_COPYDATA payload was accepted");
  }
  std::string non_ascii = "coding-agent://h/server/agent/";
  non_ascii.push_back(static_cast<char>(0xff));
  copy_data.cbData = static_cast<DWORD>(non_ascii.size() + 1);
  copy_data.lpData = non_ascii.data();
  if (DecodeAgentDeepLinkCopyData(&copy_data).has_value()) {
    return Fail("non-URI WM_COPYDATA payload was accepted");
  }

  WNDCLASSW window_class{};
  window_class.lpfnWndProc = RelayWindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kCodingAgentWindowClassName;
  if (RegisterClassW(&window_class) == 0) {
    return Fail("relay test window class could not be registered");
  }
  HWND relay_window =
      CreateWindowW(kCodingAgentWindowClassName, L"relay-test", 0, 0, 0, 0, 0,
                    nullptr, nullptr, window_class.hInstance, nullptr);
  if (relay_window == nullptr) {
    UnregisterClassW(kCodingAgentWindowClassName, window_class.hInstance);
    return Fail("relay test window could not be created");
  }
  SetPropW(relay_window, kCodingAgentWindowPropertyName,
           reinterpret_cast<HANDLE>(static_cast<INT_PTR>(1)));
  const std::string relayed = "coding-agent://h/server/agent/relayed-agent";
  if (!RelayAgentDeepLinkToExistingWindow(relayed) ||
      g_relayed_uri != relayed) {
    DestroyWindow(relay_window);
    UnregisterClassW(kCodingAgentWindowClassName, window_class.hInstance);
    return Fail("existing window did not acknowledge the relayed link");
  }
  RemovePropW(relay_window, kCodingAgentWindowPropertyName);
  DestroyWindow(relay_window);
  UnregisterClassW(kCodingAgentWindowClassName, window_class.hInstance);
  return 0;
}
