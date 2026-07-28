import '../server/daemon_config_store.dart';
import 'agent_hook_installer.dart';

/// Applies the default-disabled terminal hook setting at startup and tracks
/// live changes until the returned unsubscribe callback is invoked.
void Function() applyTerminalAgentHookSetting({
  required DaemonConfigStore store,
  AgentHookInstallOptions installOptions = const AgentHookInstallOptions(),
  AgentHookWarningLogger? onWarning,
  void Function(Object error)? onUninstallWarning,
}) {
  void apply(bool enabled) {
    if (enabled) {
      installRegisteredAgentHooks(
        options: installOptions,
        onWarning: onWarning,
      );
      return;
    }
    try {
      uninstallRegisteredAgentHooks(options: installOptions);
    } catch (error) {
      onUninstallWarning?.call(error);
    }
  }

  if (store.enableTerminalAgentHooks) {
    apply(true);
  }
  return store.onEnableTerminalAgentHooksChanged(apply);
}
