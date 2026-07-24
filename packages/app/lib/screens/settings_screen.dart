import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../core/desktop/desktop_shell.dart';
import '../core/provider_display.dart';
import '../state/connection_settings_provider.dart';
import '../state/daemon_providers.dart';
import '../state/desktop_settings_provider.dart';

/// Daemon connection settings: host/port/token, persisted across launches.
/// Saving reconnects the client, so a phone can point at a desktop over LAN.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved. Reconnecting…')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(daemonClientProvider);
    final connection =
        ref.watch(connectionStateProvider).value ?? client.currentState;
    final (color, label) = switch (connection) {
      DaemonConnectionState.connected => (Colors.greenAccent, 'Connected'),
      DaemonConnectionState.connecting => (Colors.amber, 'Connecting…'),
      DaemonConnectionState.disconnected => (
          Colors.redAccent,
          'Disconnected (retrying)',
        ),
      DaemonConnectionState.versionMismatch => (
          Colors.orangeAccent,
          'Version mismatch',
        ),
    };
    final settings = ref.watch(connectionSettingsProvider);
    final rejectedHello = client.rejectedHello;

    return Scaffold(
      appBar: AppBar(title: const Text('Connection Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Row(
                  children: [
                    Icon(Icons.circle, size: 12, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$label — ${settings.uri}',
                        style: Theme.of(context).textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (connection == DaemonConnectionState.versionMismatch &&
                    rejectedHello != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        versionMismatchMessage(rejectedHello),
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                TextFormField(
                  controller: _host,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    hintText: '127.0.0.1 or a LAN address',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      (value == null || value.trim().isEmpty)
                          ? 'Host is required'
                          : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _port,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    border: OutlineInputBorder(),
                  ),
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
                const SizedBox(height: 16),
                TextFormField(
                  controller: _token,
                  decoration: const InputDecoration(
                    labelText: 'Token (optional)',
                    helperText: 'Required when the daemon enforces auth',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save & Reconnect'),
                ),
                const SizedBox(height: 32),
                Text(
                  'AI Providers',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const _ProviderCredentialsSection(),
                if (isDesktopShell) ...[
                  const SizedBox(height: 32),
                  Text(
                    'Desktop',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const _DesktopSettingsSection(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tray-residency toggles; only rendered when [isDesktopShell].
class _DesktopSettingsSection extends ConsumerWidget {
  const _DesktopSettingsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = ref.watch(desktopSettingsProvider);
    final notifier = ref.read(desktopSettingsProvider.notifier);
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Start at login'),
          subtitle: const Text('Launch hidden in the tray when you sign in'),
          value: desktop.autoStartAtLogin,
          onChanged: (value) => notifier.setAutoStartAtLogin(value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep daemon running after quit'),
          subtitle: const Text(
            'When off, quitting the app also stops the local daemon',
          ),
          value: desktop.keepRunningAfterQuit,
          onChanged: (value) => notifier.setKeepRunningAfterQuit(value),
        ),
      ],
    );
  }
}

/// API-key entry + connection test per native LLM provider.
class _ProviderCredentialsSection extends ConsumerStatefulWidget {
  const _ProviderCredentialsSection();

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${providerDisplayName(id.name)} API key saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to save key: $e')));
    } finally {
      if (mounted) setState(() => _busy[id] = false);
    }
  }

  Future<void> _test(ProviderId id) async {
    setState(() => _busy[id] = true);
    try {
      final apiKey = _controllers[id]!.text.trim();
      final result = await ref.read(providerCredentialActionsProvider).testKey(
            id,
            apiKey: apiKey.isEmpty ? null : apiKey,
          );
      if (!mounted) return;
      setState(() => _testResults[id] = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _testResults[id] =
          ProviderCredentialTestResult(ok: false, error: '$e'));
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in ProviderId.values)
          _buildProviderTile(
            context,
            id,
            providers.where((p) => p.id == id).firstOrNull,
          ),
      ],
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
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  configured
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: configured ? Colors.greenAccent : null,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    info?.displayName ?? providerDisplayName(id.name),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (configured)
                  TextButton(
                    onPressed: busy ? null : () => _clear(id),
                    child: const Text('Remove'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controllers[id],
              obscureText: true,
              decoration: InputDecoration(
                labelText: configured ? 'Replace API key' : 'API key',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: busy ? null : () => _save(id),
                  child: const Text('Save'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: busy ? null : () => _test(id),
                  child: const Text('Test Connection'),
                ),
                if (busy) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
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
                  color: result.ok
                      ? Colors.greenAccent
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
