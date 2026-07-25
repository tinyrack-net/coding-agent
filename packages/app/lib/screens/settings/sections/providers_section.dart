import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/provider_display.dart';
import '../../../state/daemon_providers.dart';

/// API-key entry + connection test per native LLM provider.
class ProvidersSection extends ConsumerStatefulWidget {
  const ProvidersSection({super.key});

  @override
  ConsumerState<ProvidersSection> createState() => _ProvidersSectionState();
}

class _ProvidersSectionState extends ConsumerState<ProvidersSection> {
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
