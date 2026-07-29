import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart' as lifecycle;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_diagnostic_report.dart';
import '../core/daemon_client.dart';
import '../core/desktop/desktop_shell.dart';
import '../core/provider_display.dart';
import '../core/theme.dart';
import '../state/agents_provider.dart';
import '../state/appearance_provider.dart';
import '../state/connection_settings_provider.dart';
import '../state/daemon_providers.dart';
import '../state/desktop_settings_provider.dart';
import '../state/host_registry_provider.dart';
import '../state/tool_call_detail_level_provider.dart';
import '../tool_calls/detail_level/tool_call_projection.dart';
import '../widgets/fluent/toast.dart';
import 'host_settings_sections.dart';
import 'keyboard_shortcuts_settings_section.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, required this.section});

  final String section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (section) {
      'general' => _ConnectionSettingsSection(key: const ValueKey('general')),
      'agents' => const HostAgentsSettingsSection(key: ValueKey('agents')),
      'workspaces' => const HostWorkspacesSettingsSection(
        key: ValueKey('workspaces'),
      ),
      'terminals' => const HostTerminalsSettingsSection(
        key: ValueKey('terminals'),
      ),
      'providers' => _ProviderCredentialsSection(
        key: const ValueKey('providers'),
      ),
      'keyboard' => const KeyboardShortcutsSettingsSection(
        key: ValueKey('keyboard'),
      ),
      'appearance' => const _AppearanceSettingsSection(
        key: ValueKey('appearance'),
      ),
      'desktop' => _DesktopSettingsSection(key: const ValueKey('desktop')),
      'diagnostics' => const _DiagnosticsSettingsSection(
        key: ValueKey('diagnostics'),
      ),
      'reset' => _DataResetSection(key: const ValueKey('reset')),
      _ => _ConnectionSettingsSection(key: const ValueKey('general')),
    };
  }
}

class _AppearanceSettingsSection extends ConsumerWidget {
  const _AppearanceSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(appearanceProvider);
    final detailLevel = ref.watch(toolCallDetailLevelProvider);
    return ScaffoldPage(
      header: const PageHeader(title: Text('Appearance')),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              _SelectSettingsRow<AppThemeName>(
                title: 'Theme',
                subtitle: 'Choose the color theme used throughout the app.',
                value: theme,
                items: [
                  for (final value in AppThemeName.values)
                    ComboBoxItem(
                      value: value,
                      child: Text(
                        value.name[0].toUpperCase() + value.name.substring(1),
                      ),
                    ),
                ],
                onChanged: (value) =>
                    ref.read(appearanceProvider.notifier).setTheme(value),
              ),
              const SizedBox(height: 12),
              _SelectSettingsRow<ToolCallDetailLevel>(
                title: 'Tool call detail',
                subtitle:
                    'Show every tool call or combine consecutive calls into '
                    'an overview.',
                value: detailLevel,
                items: const [
                  ComboBoxItem(
                    value: ToolCallDetailLevel.detailed,
                    child: Text('Detailed'),
                  ),
                  ComboBoxItem(
                    value: ToolCallDetailLevel.overview,
                    child: Text('Overview'),
                  ),
                ],
                onChanged: (value) => ref
                    .read(toolCallDetailLevelProvider.notifier)
                    .setLevel(value),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectSettingsRow<T> extends StatelessWidget {
  const _SelectSettingsRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final T value;
  final List<ComboBoxItem<T>> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Row(
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
      const SizedBox(width: 16),
      SizedBox(
        width: 160,
        child: ComboBox<T>(
          value: value,
          items: items,
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    ],
  );
}

class _DiagnosticsSettingsSection extends ConsumerStatefulWidget {
  const _DiagnosticsSettingsSection({super.key});

  @override
  ConsumerState<_DiagnosticsSettingsSection> createState() =>
      _DiagnosticsSettingsSectionState();
}

class _DiagnosticsSettingsSectionState
    extends ConsumerState<_DiagnosticsSettingsSection> {
  String? _diagnostic;
  Object? _error;
  bool _loading = false;
  int _runId = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_collect);
  }

  Future<void> _collect() async {
    final runId = ++_runId;
    setState(() {
      _loading = true;
      _diagnostic = null;
      _error = null;
    });
    final registry = ref.read(hostRegistryProvider);
    final client = ref.read(daemonClientProvider);
    final sections = <String>[
      formatAppDiagnosticHeader(
        collectedAt: DateTime.now(),
        appVersion: lifecycle.daemonVersion,
        platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
        isDesktopApp: isDesktopShell,
        hostCount: registry.hosts.length,
      ),
    ];
    try {
      final host = registry.activeHost;
      if (host != null) {
        HostConnection? active;
        for (final connection in host.connections) {
          if (connection.id == host.preferredConnectionId) {
            active = connection;
            break;
          }
        }
        sections.add(
          formatHostDiagnosticSection(
            host: host,
            status: client.currentState.name,
            activeConnection: active == null
                ? 'none'
                : describeConnectionKind(active),
          ),
        );
      }
      sections.add(formatServerInfoSection(client.serverInfo));
      if (client.currentState == DaemonConnectionState.connected &&
          client.serverInfo?.features['daemonDiagnostics'] == true) {
        sections.add(await client.getDiagnostics());
      } else {
        sections.add(
          formatDiagnosticSection('Daemon diagnostics', const [
            ('Status', 'unsupported or host is not connected'),
          ]),
        );
      }
      if (!mounted || runId != _runId) return;
      setState(() {
        _diagnostic = redactAppDiagnosticReport(
          sections.join('\n\n'),
          registry.hosts,
        );
        _loading = false;
      });
    } catch (error) {
      sections.add(
        formatDiagnosticSection('Host diagnostics', [('Error', '$error')]),
      );
      if (!mounted || runId != _runId) return;
      setState(() {
        _diagnostic = redactAppDiagnosticReport(
          sections.join('\n\n'),
          registry.hosts,
        );
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _copy() async {
    final diagnostic = _diagnostic;
    if (diagnostic == null) return;
    await Clipboard.setData(ClipboardData(text: diagnostic));
    if (mounted) AppToast.show(context, 'Diagnostic copied.');
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage.scrollable(
      key: const Key('app-diagnostics-page'),
      header: const PageHeader(title: Text('Diagnostics')),
      children: [
        const Text(
          'Collect app, host, connection, and daemon diagnostics. '
          'Connection secrets are removed before display or copy.',
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Button(
              key: const Key('copy-diagnostic'),
              onPressed: _diagnostic == null ? null : _copy,
              child: const Text('Copy diagnostic'),
            ),
            const SizedBox(width: 8),
            Button(
              key: const Key('refresh-diagnostic'),
              onPressed: _loading ? null : _collect,
              child: Text(_loading ? 'Running diagnostic…' : 'Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_loading && _diagnostic == null)
          const Card(
            child: Row(
              children: [
                ProgressRing(strokeWidth: 2),
                SizedBox(width: 12),
                Text('Running diagnostic…'),
              ],
            ),
          )
        else if (_diagnostic != null)
          Card(
            key: const Key('diagnostic-report'),
            child: SizedBox(
              width: double.infinity,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 240),
                child: SelectableText(
                  _diagnostic!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            'Some diagnostics failed: $_error',
            style: TextStyle(color: Colors.red),
          ),
        ],
      ],
    );
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
    await ref
        .read(connectionSettingsProvider.notifier)
        .save(
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
                  child: TextFormBox(controller: _token, obscureText: true),
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
        content: const Center(
          child: Text('Desktop settings are only available on Windows/macOS.'),
        ),
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

class _ProviderCredentialsSection extends ConsumerStatefulWidget {
  const _ProviderCredentialsSection({super.key});

  @override
  ConsumerState<_ProviderCredentialsSection> createState() =>
      _ProviderCredentialsSectionState();
}

class _ProviderCredentialsSectionState
    extends ConsumerState<_ProviderCredentialsSection> {
  final _controllers = {
    for (final id in ProviderId.values) id: TextEditingController(),
  };
  final _testResults = <ProviderId, ProviderCredentialTestResult?>{};
  final _busy = <ProviderId, bool>{};

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save(ProviderId id) async {
    final apiKey = _controllers[id]!.text.trim();
    if (apiKey.isEmpty) return;
    setState(() => _busy[id] = true);
    try {
      await ref.read(providerCredentialActionsProvider).setKey(id, apiKey);
      if (!mounted) return;
      setState(() {
        _testResults[id] = null;
        _controllers[id]!.clear();
      });
      AppToast.show(context, '${providerDisplayName(id.name)} API key saved');
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Failed to save key: $e',
        severity: InfoBarSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _busy[id] = false);
    }
  }

  Future<void> _test(ProviderId id) async {
    setState(() => _busy[id] = true);
    try {
      final apiKey = _controllers[id]!.text.trim();
      final result = await ref
          .read(providerCredentialActionsProvider)
          .testKey(id, apiKey: apiKey.isEmpty ? null : apiKey);
      if (!mounted) return;
      setState(() => _testResults[id] = result);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _testResults[id] = ProviderCredentialTestResult(
          ok: false,
          error: '$e',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy[id] = false);
    }
  }

  Future<void> _clear(ProviderId id) async {
    setState(() => _busy[id] = true);
    try {
      await ref.read(providerCredentialActionsProvider).clearKey(id);
      if (!mounted) return;
      setState(() => _testResults[id] = null);
    } finally {
      if (mounted) setState(() => _busy[id] = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers =
        ref.watch(providerListProvider).value ?? const <ProviderInfo>[];
    return ScaffoldPage(
      header: const PageHeader(title: Text('AI Providers')),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              for (final id in ProviderId.values)
                _buildProviderTile(
                  context,
                  id,
                  providers.where((p) => p.id == id).firstOrNull,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProviderTile(
    BuildContext context,
    ProviderId id,
    ProviderInfo? info,
  ) {
    final configured = info?.configured ?? false;
    final busy = _busy[id] ?? false;
    final result = _testResults[id];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                configured
                    ? FluentIcons.completed_solid
                    : FluentIcons.circle_ring,
                color: configured ? Colors.green : null,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  info?.displayName ?? providerDisplayName(id.name),
                  style: context.textStyles.titleSmall,
                ),
              ),
              if (configured)
                Button(
                  onPressed: busy ? null : () => _clear(id),
                  child: const Text('Remove'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextBox(
            controller: _controllers[id],
            obscureText: true,
            placeholder: configured ? 'Replace API key' : 'API key',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: busy ? null : () => _save(id),
                child: const Text('Save'),
              ),
              const SizedBox(width: 8),
              Button(
                onPressed: busy ? null : () => _test(id),
                child: const Text('Test Connection'),
              ),
              if (busy) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: ProgressRing(strokeWidth: 2),
                ),
              ],
            ],
          ),
          if (result != null) ...[
            const SizedBox(height: 8),
            Text(
              result.ok
                  ? 'Connection OK'
                  : (result.error ?? 'Connection failed'),
              style: TextStyle(
                color: result.ok ? Colors.green : context.tokens.error,
              ),
            ),
          ],
        ],
      ),
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
          '• Remove every stored LLM provider API key\n'
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

    final providers =
        ref.read(providerListProvider).value ?? const <ProviderInfo>[];
    final configuredIds = providers
        .where((p) => p.configured)
        .map((p) => p.id)
        .toList();

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

    final actions = ref.read(providerCredentialActionsProvider);
    for (final id in configuredIds) {
      try {
        await actions.clearKey(id);
      } catch (e) {
        failures.add('${providerDisplayName(id.name)} key: $e');
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
            children: [_buildResetCard(context)],
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
                          strokeWidth: 2,
                          activeColor: Colors.white,
                        ),
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
