#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kAgentNavigationChannel[] = "tinyrack/agent_navigation";

void ActivateWindow(HWND window) {
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    ::ShowWindow(window, SW_SHOW);
  }
  ::SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  if (!::SetForegroundWindow(window)) {
    FLASHWINFO flash_info{
        sizeof(FLASHWINFO), window, FLASHW_TRAY | FLASHW_TIMERNOFG, 3, 0,
    };
    ::FlashWindowEx(&flash_info);
  }
}

} // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject &project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  ::SetPropW(GetHandle(), kCodingAgentWindowPropertyName,
             reinterpret_cast<HANDLE>(static_cast<INT_PTR>(1)));

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  agent_navigation_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kAgentNavigationChannel,
          &flutter::StandardMethodCodec::GetInstance());
  agent_navigation_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue> &call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "listen") {
          agent_navigation_inbox_.SetReady(true);
          const auto pending = agent_navigation_inbox_.TakePending();
          if (pending.has_value()) {
            result->Success(flutter::EncodableValue(pending.value()));
          } else {
            result->Success();
          }
          return;
        }
        if (call.method_name() == "cancel") {
          agent_navigation_inbox_.SetReady(false);
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (GetHandle() != nullptr) {
    ::RemovePropW(GetHandle(), kCodingAgentWindowPropertyName);
  }
  agent_navigation_inbox_.SetReady(false);
  agent_navigation_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_COPYDATA) {
    const auto uri = DecodeAgentDeepLinkCopyData(
        reinterpret_cast<const COPYDATASTRUCT *>(lparam));
    if (uri.has_value()) {
      ActivateWindow(hwnd);
      if (agent_navigation_inbox_.ready() && agent_navigation_channel_) {
        agent_navigation_channel_->InvokeMethod(
            "open", std::make_unique<flutter::EncodableValue>(uri.value()));
      } else {
        agent_navigation_inbox_.Push(uri.value());
      }
      return TRUE;
    }
    const auto *copy_data = reinterpret_cast<const COPYDATASTRUCT *>(lparam);
    if (copy_data != nullptr && copy_data->dwData == kCodingAgentCopyDataId) {
      return FALSE;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
  case WM_FONTCHANGE:
    flutter_controller_->engine()->ReloadSystemFonts();
    break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
