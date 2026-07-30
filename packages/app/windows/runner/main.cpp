#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "agent_navigation.h"
#include "flutter_window.h"
#include "protocol_registration.h"
#include "utils.h"

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

  const LSTATUS protocol_status = RegisterCodingAgentProtocol();
  if (protocol_status != ERROR_SUCCESS) {
    const std::wstring message =
        L"Failed to register coding-agent protocol for the current user: " +
        std::to_wstring(protocol_status) + L"\n";
    ::OutputDebugStringW(message.c_str());
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, FALSE, kCodingAgentInstanceMutexName);
  const bool existing_instance =
      instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS;
  const auto agent_deep_link =
      FindAgentDeepLinkArgument(command_line_arguments);
  if (existing_instance && agent_deep_link.has_value() &&
      RelayAgentDeepLinkToExistingWindow(agent_deep_link.value())) {
    ::CloseHandle(instance_mutex);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"coding_agent_app", origin, size)) {
    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
