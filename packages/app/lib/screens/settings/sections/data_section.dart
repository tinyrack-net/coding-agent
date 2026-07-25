import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/desktop/desktop_shell.dart';
import '../../../core/provider_display.dart';
import '../../../state/agents_provider.dart';
import '../../../state/connection_settings_provider.dart';
import '../../../state/daemon_providers.dart';
import '../../../state/desktop_settings_provider.dart';

/// "Reset all data" — clears local app settings (host/port/token, desktop
/// toggles) and best-effort removes any stored provider API keys on the
/// daemon. Confirmation is required; the action is not undoable.
class DataSection extends ConsumerStatefulWidget {
  const DataSection({super.key});

  @override
  ConsumerState<DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends ConsumerState<DataSection> {
  bool _busy = false;

  Future<void> _confirmAndReset() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset all data?'),
        content: const Text(
          'This will:\n'
          '• Clear the daemon host, port, and token (back to defaults)\n'
          '• Reset desktop startup and tray preferences\n'
          '• Remove every stored LLM provider API key\n'
          '• Wipe every conversation (agent timelines, history)\n\n'
          'You will need to re-enter your API keys and reconnect. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset all data'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);

    // Capture the currently-configured providers before we kick the reset,
    // since `providerListProvider` will be invalidated as keys are cleared.
    final providers =
        ref.read(providerListProvider).value ?? const <ProviderInfo>[];
    final configuredIds = providers
        .where((p) => p.configured)
        .map((p) => p.id)
        .toList();

    final failures = <String>[];

    // 1. Reset app-side settings first — this is guaranteed-local work.
    try {
      await ref.read(connectionSettingsProvider.notifier).reset();
    } catch (e) {
      failures.add('connection settings: $e');
    }
    if (isDesktopShell) {
      try {
        await ref.read(desktopSettingsProvider.notifier).reset();
      } catch (e) {
        failures.add('desktop settings: $e');
      }
    }

    // 2. Best-effort: ask the daemon to clear each configured provider key.
    //    If the daemon is unreachable, surface that in the snackbar but keep
    //    the local reset intact.
    final actions = ref.read(providerCredentialActionsProvider);
    for (final id in configuredIds) {
      try {
        await actions.clearKey(id);
      } catch (e) {
        failures.add('${providerDisplayName(id.name)} key: $e');
      }
    }

    // Invalidate so the providers card reflects the cleared state.
    ref.invalidate(providerListProvider);

    // 3. Wipe every agent's conversation on the daemon. This tears down
    //    provider sessions and clears persisted timeline files; the next
    //    prompt on any surviving agent will start a brand-new provider
    //    session with empty history.
    int? clearedAgents;
    try {
      clearedAgents = await ref.read(agentActionsProvider).clearConversations();
    } catch (e) {
      failures.add('conversations: $e');
    }

    if (!mounted) return;
    setState(() => _busy = false);

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (failures.isEmpty) {
      final summary = clearedAgents == null
          ? 'All data has been reset.'
          : 'All data has been reset '
              '(${clearedAgents == 0 ? 'no' : clearedAgents} '
              'conversation${clearedAgents == 1 ? '' : 's'} wiped).';
      messenger.showSnackBar(SnackBar(content: Text(summary)));
    } else {
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            'Local data reset. Some daemon-side items could not be cleared: '
            '${failures.join('; ')}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keep the provider list warm so `_confirmAndReset` doesn't race an
    // unresolved fetch when this section is opened without visiting the
    // AI Providers section first.
    ref.watch(providerListProvider);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reset all data',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Clears the daemon connection, desktop preferences, every saved '
              'provider API key, and every conversation (agent timelines + '
              'history). The app will reconnect to the default localhost '
              'daemon.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: _busy ? null : _confirmAndReset,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.restart_alt),
              label: Text(_busy ? 'Resetting…' : 'Reset all data'),
            ),
          ],
        ),
      ),
    );
  }
}
