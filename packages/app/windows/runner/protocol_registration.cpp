#include "protocol_registration.h"

#include <algorithm>
#include <limits>
#include <vector>

namespace {

constexpr wchar_t kProtocolRegistryPath[] = L"Software\\Classes\\coding-agent";
constexpr wchar_t kProtocolDescription[] = L"URL:Coding Agent Protocol";
constexpr wchar_t kProtocolValueName[] = L"URL Protocol";
constexpr size_t kMaximumWindowsPathBufferLength = 32768;

std::wstring Quote(const std::wstring &value) { return L"\"" + value + L"\""; }

std::wstring GetExecutablePath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  while (buffer.size() <= kMaximumWindowsPathBufferLength) {
    SetLastError(ERROR_SUCCESS);
    const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                            static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return {};
    }
    if (length < buffer.size() - 1 ||
        (length < buffer.size() &&
         GetLastError() != ERROR_INSUFFICIENT_BUFFER)) {
      return std::wstring(buffer.data(), length);
    }
    const size_t next_size =
        (std::min)(buffer.size() * 2,
                   kMaximumWindowsPathBufferLength);
    if (next_size <= buffer.size()) {
      return {};
    }
    buffer.resize(next_size);
  }
  return {};
}

LSTATUS WriteRegistryEntry(const ProtocolRegistryEntry &entry) {
  HKEY key = nullptr;
  const LSTATUS create_status = RegCreateKeyExW(
      HKEY_CURRENT_USER, entry.subkey.c_str(), 0, nullptr,
      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key, nullptr);
  if (create_status != ERROR_SUCCESS) {
    return create_status;
  }

  const wchar_t *value_name =
      entry.value_name.has_value() ? entry.value_name->c_str() : nullptr;
  const size_t character_count = entry.value.size() + 1;
  if (character_count > (std::numeric_limits<DWORD>::max)() / sizeof(wchar_t)) {
    RegCloseKey(key);
    return ERROR_INVALID_DATA;
  }
  const DWORD byte_count =
      static_cast<DWORD>(character_count * sizeof(wchar_t));
  const LSTATUS write_status = RegSetValueExW(
      key, value_name, 0, REG_SZ,
      reinterpret_cast<const BYTE *>(entry.value.c_str()), byte_count);
  RegCloseKey(key);
  return write_status;
}

} // namespace

std::vector<ProtocolRegistryEntry>
BuildCodingAgentProtocolRegistration(const std::wstring &executable_path) {
  if (executable_path.empty() ||
      executable_path.find(L'"') != std::wstring::npos) {
    return {};
  }

  const std::wstring quoted_executable = Quote(executable_path);
  return {
      {kProtocolRegistryPath, std::nullopt, kProtocolDescription},
      {kProtocolRegistryPath, kProtocolValueName, L""},
      {std::wstring(kProtocolRegistryPath) + L"\\DefaultIcon", std::nullopt,
       quoted_executable + L",0"},
      {std::wstring(kProtocolRegistryPath) + L"\\shell\\open\\command",
       std::nullopt, quoted_executable + L" \"%1\""},
  };
}

LSTATUS RegisterCodingAgentProtocol() {
  const std::wstring executable_path = GetExecutablePath();
  const auto entries = BuildCodingAgentProtocolRegistration(executable_path);
  if (entries.empty()) {
    return ERROR_INVALID_PARAMETER;
  }
  for (const auto &entry : entries) {
    const LSTATUS status = WriteRegistryEntry(entry);
    if (status != ERROR_SUCCESS) {
      return status;
    }
  }
  return ERROR_SUCCESS;
}
