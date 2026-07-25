import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/daemon_client.dart';
import '../../../state/connection_settings_provider.dart';
import '../../../state/daemon_providers.dart';

/// Daemon connection settings: host/port/token, persisted across launches.
/// Saving reconnects the client, so a phone can point at a desktop over LAN.
class ConnectionSection extends ConsumerStatefulWidget {
  const ConnectionSection({super.key});

  @override
  ConsumerState<ConnectionSection> createState() => _ConnectionSectionState();
}

class _ConnectionSectionState extends ConsumerState<ConnectionSection> {
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

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    color: Theme.of(context).colorScheme.onErrorContainer,
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
            validator: (value) => (value == null || value.trim().isEmpty)
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
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save & Reconnect'),
            ),
          ),
        ],
      ),
    );
  }
}
