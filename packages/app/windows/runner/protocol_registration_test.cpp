#include "protocol_registration.h"

#include <iostream>
#include <string>
#include <vector>

namespace {

int Fail(const char *message) {
  std::cerr << message << std::endl;
  return 1;
}

} // namespace

int main() {
  const std::wstring executable =
      L"C:\\Program Files\\Tinyrack\\coding_agent_app.exe";
  const std::vector<ProtocolRegistryEntry> entries =
      BuildCodingAgentProtocolRegistration(executable);
  if (entries.size() != 4) {
    return Fail("expected four protocol registry values");
  }
  for (const auto &entry : entries) {
    if (entry.subkey.rfind(L"Software\\Classes\\coding-agent", 0) != 0) {
      return Fail("registration escaped the current-user protocol subtree");
    }
  }
  if (entries[0].value_name.has_value() ||
      entries[0].value != L"URL:Coding Agent Protocol") {
    return Fail("protocol description is incorrect");
  }
  if (!entries[1].value_name.has_value() ||
      entries[1].value_name.value() != L"URL Protocol" ||
      !entries[1].value.empty()) {
    return Fail("URL Protocol marker is incorrect");
  }
  if (entries[2].value != L"\"" + executable + L"\",0") {
    return Fail("default icon does not quote the executable");
  }
  if (entries[3].value != L"\"" + executable + L"\" \"%1\"") {
    return Fail("open command does not quote the executable and URI");
  }
  if (!BuildCodingAgentProtocolRegistration(L"").empty()) {
    return Fail("empty executable path was accepted");
  }
  if (!BuildCodingAgentProtocolRegistration(L"C:\\bad\"path.exe").empty()) {
    return Fail("unsafe executable path was accepted");
  }
  return 0;
}
