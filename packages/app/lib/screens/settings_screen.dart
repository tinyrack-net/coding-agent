import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../core/desktop/desktop_shell.dart';
import '../core/theme.dart';
import '../state/agents_provider.dart';
import '../state/connection_settings_provider.dart';
import '../state/daemon_providers.dart';
import '../state/desktop_settings_provider.dart';
import '../widgets/fluent/toast.dart';
import 'settings/provider_settings_section.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, required this.section});

  final String section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (section) {
      'general' => _ConnectionSettingsSection(key: const ValueKey('general')),
      'providers' =>
        const ProviderSettingsSection(key: ValueKey('providers')),
      'desktop' => _DesktopSettingsSection(key: const ValueKey('desktop')),
      'reset' => _DataResetSection(key: const ValueKey('reset')),
      _ => _ConnectionSettingsSection(key: const ValueKey('general')),
    };
  }
}

class _ConnectionSettingsSection extends ConsumerStatefulWidget {
  const _ConnectionSettingsSection({super.key});

  @override
  ConsumerState<_ConnectionSettingsSection> createState() =>
      _ConnectionSettingsSectionState();
}

class _ConnectionSettingsSectionState
    extends ConsumerState<_ConnectionSettingsSection> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _token;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(connectionSettingsProvider);
    _host = TextEditingController(text: settings.host);
    _port = TextEditingController(text: '${settings.port}');
    _token = TextEditingController(text: settings.token ?? '');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await ref.read(connectionSettingsProvider.notifier).save(
          host: _host.text.trim(),
          port: int.parse(_port.text.trim()),
          token: _token.text.trim(),
        );
    if (!mounted) return;
    AppToast.show(context, 'Settings saved. Reconnecting…');
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(daemonClientProvider);
    final connection =
        ref.watch(connectionStateProvider).value ?? client.currentState;
    final (color, label) = switch (connection) {
      DaemonConnectionState.connected => (Colors.green, 'Connected'),
      DaemonConnectionState.connecting => (Colors.yellow, 'Connecting…'),
      DaemonConnectionState.disconnected => (
          Colors.red,
          'Disconnected (retrying)',
        ),
      DaemonConnectionState.versionMismatch => (
          Colors.orange,
          'Version mismatch',
        ),
    };
    final settings = ref.watch(connectionSettingsProvider);
    final rejectedHello = client.rejectedHello;

    return ScaffoldPage(
      header: const PageHeader(title: Text('Connection Settings')),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Row(
                  children: [
                    Icon(FluentIcons.circle_fill, size: 12, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$label — ${settings.uri}',
                        style: context.textStyles.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (connection == DaemonConnectionState.versionMismatch &&
                    rejectedHello != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    backgroundColor: context.tokens.errorContainer,
                    child: Text(
                      versionMismatchMessage(rejectedHello),
                      style: TextStyle(color: context.tokens.onErrorContainer),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                InfoLabel(
                  label: 'Host',
                  child: TextFormBox(
                    controller: _host,
                    placeholder: '127.0.0.1 or a LAN address',
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                            ? 'Host is required'
                            : null,
                  ),
                ),
                const SizedBox(height: 16),
                InfoLabel(
                  label: 'Port',
                  child: TextFormBox(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) {
                      final port = int.tryParse(value?.trim() ?? '');
                      if (port == null || port < 1 || port > 65535) {
                        return 'Enter a port between 1 and 65535';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(height: 16),
                InfoLabel(
                  label: 'Token (optional)',
                  child: TextFormBox(
                    controller: _token,
                    obscureText: true,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Required when the daemon enforces auth',
                    style: context.textStyles.bodySmall,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _save,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.save, size: 16),
                      SizedBox(width: 6),
                      Text('Save & Reconnect'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopSettingsSection extends ConsumerWidget {
  const _DesktopSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktopShell) {
      return ScaffoldPage(
        header: const PageHeader(title: Text('Desktop')),
        content: const Center(child: Text('Desktop settings are only available on Windows/macOS.')),
      );
    }
    final desktop = ref.watch(desktopSettingsProvider);
    final notifier = ref.read(desktopSettingsProvider.notifier);
    return ScaffoldPage(
      header: const PageHeader(title: Text('Desktop Settings')),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              _ToggleRow(
                title: 'Start at login',
                subtitle: 'Launch hidden in the tray when you sign in',
                value: desktop.autoStartAtLogin,
                onChanged: notifier.setAutoStartAtLogin,
              ),
              const SizedBox(height: 12),
              _ToggleRow(
                title: 'Keep daemon running after quit',
                subtitle:
                    'When off, quitting the app also stops the local daemon',
                value: desktop.keepRunningAfterQuit,
                onChanged: notifier.setKeepRunningAfterQuit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              Text(subtitle, style: context.textStyles.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ToggleSwitch(checked: value, onChanged: onChanged),
      ],
    );
  }
}


class _DataResetSection extends ConsumerStatefulWidget {
  const _DataResetSection({super.key});

  @override
  ConsumerState<_DataResetSection> createState() => _DataResetSectionState();
}

class _DataResetSectionState extends ConsumerState<_DataResetSection> {
  bool _busy = false;

  Future<void> _confirmAndReset() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: const Text('Reset all data?'),
        content: const Text(
          'This will:\n'
          '• Clear the daemon host, port, and token (back to defaults)\n'
          '• Reset desktop startup and tray preferences\n'
          '• Remove every configured LLM provider and its API key\n'
          '• Wipe every conversation (agent timelines, history)\n\n'
          'You will need to re-enter your API keys and reconnect. '
          'This cannot be undone.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.all(
                FluentTheme.of(dialogContext).resources.systemFillColorCritical,
              ),
              foregroundColor: const WidgetStatePropertyAll(Colors.white),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset all data'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);

    // Snapshot before mutating: deleting providers invalidates the list.
    final providers =
        ref.read(providerListProvider).value ?? const <ProviderInfo>[];

    final failures = <String>[];

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

    // Delete rather than just clearing keys: providers are user data now, so a
    // reset that left providers.json populated wouldn't be a reset.
    final actions = ref.read(providerActionsProvider);
    for (final provider in providers) {
      try {
        await actions.delete(provider.id);
      } catch (e) {
        failures.add('${provider.displayName}: $e');
      }
    }

    ref.invalidate(providerListProvider);

    int? clearedAgents;
    try {
      clearedAgents = await ref.read(agentActionsProvider).clearConversations();
    } catch (e) {
      failures.add('conversations: $e');
    }

    if (!mounted) return;
    setState(() => _busy = false);

    AppToast.dismissCurrent();
    if (failures.isEmpty) {
      final summary = clearedAgents == null
          ? 'All data has been reset.'
          : 'All data has been reset '
              '(${clearedAgents == 0 ? 'no' : clearedAgents} '
              'conversation${clearedAgents == 1 ? '' : 's'} wiped).';
      AppToast.show(context, summary);
    } else {
      AppToast.show(
        context,
        'Local data reset. Some daemon-side items could not be cleared: '
        '${failures.join('; ')}',
        severity: InfoBarSeverity.warning,
        duration: const Duration(seconds: 6),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(providerListProvider);
    return ScaffoldPage(
      header: const PageHeader(title: Text('Data Reset')),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              _buildResetCard(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResetCard(BuildContext context) {
    final tokens = context.tokens;
    return Card(
      backgroundColor: tokens.errorContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reset all data',
            style: context.textStyles.titleSmall?.copyWith(
              color: tokens.onErrorContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Clears the daemon connection, desktop preferences, every saved '
            'provider API key, and every conversation (agent timelines + '
            'history). The app will reconnect to the default localhost '
            'daemon.',
            style: context.textStyles.bodySmall?.copyWith(
              color: tokens.onErrorContainer,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.all(tokens.error),
              foregroundColor: const WidgetStatePropertyAll(Colors.white),
            ),
            onPressed: _busy ? null : _confirmAndReset,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: ProgressRing(
                            strokeWidth: 2, activeColor: Colors.white),
                      )
                    : const Icon(FluentIcons.reset, size: 16),
                const SizedBox(width: 6),
                Text(_busy ? 'Resetting…' : 'Reset all data'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
