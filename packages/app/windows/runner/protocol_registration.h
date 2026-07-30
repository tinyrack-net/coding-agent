#ifndef RUNNER_PROTOCOL_REGISTRATION_H_
#define RUNNER_PROTOCOL_REGISTRATION_H_

#include <windows.h>

#include <optional>
#include <string>
#include <vector>

struct ProtocolRegistryEntry {
  std::wstring subkey;
  std::optional<std::wstring> value_name;
  std::wstring value;
};

// Builds the complete user-scoped registration plan for coding-agent://.
// Returns an empty plan when |executable_path| cannot be safely quoted.
std::vector<ProtocolRegistryEntry>
BuildCodingAgentProtocolRegistration(const std::wstring &executable_path);

// Registers coding-agent:// for the current user. This is intentionally
// user-scoped and idempotent: it only creates or updates values below
// HKCU\Software\Classes\coding-agent and never removes registry data.
LSTATUS RegisterCodingAgentProtocol();

#endif // RUNNER_PROTOCOL_REGISTRATION_H_
