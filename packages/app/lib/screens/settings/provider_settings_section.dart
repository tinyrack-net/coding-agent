import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_display.dart';
import '../../core/provider_presets.dart';
import '../../core/theme.dart';
import '../../state/daemon_providers.dart';
import '../../widgets/fluent/search_picker_dialog.dart';
import '../../widgets/fluent/toast.dart';
import 'provider_form_dialog.dart';

/// Settings → AI Providers: a list of user-configured providers, each editable
/// and deletable, plus an "Add provider" flow seeded from a preset.
class ProviderSettingsSection extends ConsumerStatefulWidget {
  const ProviderSettingsSection({super.key});

  @override
  ConsumerState<ProviderSettingsSection> createState() =>
      _ProviderSettingsSectionState();
}

class _ProviderSettingsSectionState
    extends ConsumerState<ProviderSettingsSection> {
  /// Per-provider in-flight flag, so one row's Test doesn't disable the others.
  final _busy = <String, bool>{};
  final _testResults = <String, ProviderCredentialTestResult?>{};
  bool _adding = false;

  Future<void> _add() async {
    final preset = await showDialog<ProviderPreset>(
      context: context,
      builder: (_) => SearchPickerDialog<ProviderPreset>(
        title: 'Add provider',
        items: ProviderPresets.all,
        itemLabel: (p) => p.displayName,
        searchHint: 'Search providers',
      ),
    );
    if (preset == null || !mounted) return;

    setState(() => _adding = true);
    try {
      await showProviderFormDialog(context, ref, draft: preset.toConfig());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _edit(ProviderInfo info) async {
    await showProviderFormDialog(context, ref, draft: info.toConfig());
  }

  Future<void> _test(ProviderInfo info) async {
    setState(() => _busy[info.id] = true);
    try {
      final result = await ref.read(providerActionsProvider).testKey(info.id);
      if (!mounted) return;
      setState(() => _testResults[info.id] = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _testResults[info.id] =
          ProviderCredentialTestResult(ok: false, error: '$e'));
    } finally {
      if (mounted) setState(() => _busy[info.id] = false);
    }
  }

  Future<void> _delete(ProviderInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: Text('Delete ${info.displayName}?'),
        content: const Text(
          'This removes the provider and its stored API key.\n\n'
          'Existing agents that use this provider will fail to start on their '
          'next turn.',
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy[info.id] = true);
    try {
      await ref.read(providerActionsProvider).delete(info.id);
      if (!mounted) return;
      setState(() => _testResults.remove(info.id));
      AppToast.show(context, '${info.displayName} deleted');
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, 'Failed to delete provider: $e',
          severity: InfoBarSeverity.error);
    } finally {
      if (mounted) setState(() => _busy[info.id] = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = ref.watch(providerListProvider);
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('AI Providers'),
        commandBar: FilledButton(
          onPressed: _adding ? null : _add,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FluentIcons.add, size: 16),
              SizedBox(width: 6),
              Text('Add provider'),
            ],
          ),
        ),
      ),
      content: Center(
        child: ConstrainedBox(
          // Wider than the other sections: rows carry a base URL.
          constraints: const BoxConstraints(maxWidth: 560),
          child: switch (providers) {
            AsyncValue(:final error?) => Center(
                child: Text('Failed to load providers: $error'),
              ),
            AsyncValue(value: final list?) when list.isEmpty => const Center(
                child: Text(
                  'No providers yet. Add one to start creating workspaces.',
                ),
              ),
            AsyncValue(value: final list?) => ListView(
                padding: const EdgeInsets.all(24),
                children: [for (final info in list) _buildTile(context, info)],
              ),
            _ => const Center(child: ProgressRing()),
          },
        ),
      ),
    );
  }

  Widget _buildTile(BuildContext context, ProviderInfo info) {
    final busy = _busy[info.id] ?? false;
    final result = _testResults[info.id];
    final tokens = context.tokens;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                info.configured
                    ? FluentIcons.completed_solid
                    : FluentIcons.circle_ring,
                color: info.configured ? Colors.green : null,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  info.displayName,
                  style: context.textStyles.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _KindBadge(kind: info.kind),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            info.baseUrl,
            style: context.textStyles.bodySmall
                ?.copyWith(color: tokens.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (!info.configured && info.unavailableReason != null) ...[
            const SizedBox(height: 4),
            Text(
              info.unavailableReason!,
              style: context.textStyles.bodySmall
                  ?.copyWith(color: tokens.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Button(
                onPressed: busy ? null : () => _edit(info),
                child: const Text('Edit'),
              ),
              const SizedBox(width: 8),
              Button(
                onPressed: busy || !info.configured ? null : () => _test(info),
                child: const Text('Test Connection'),
              ),
              const Spacer(),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: ProgressRing(strokeWidth: 2),
                  ),
                ),
              Tooltip(
                message: 'Delete provider',
                child: IconButton(
                  icon: const Icon(FluentIcons.delete, size: 16),
                  onPressed: busy ? null : () => _delete(info),
                ),
              ),
            ],
          ),
          if (result != null) ...[
            const SizedBox(height: 8),
            Text(
              result.ok ? 'Connection OK' : (result.error ?? 'Connection failed'),
              style: TextStyle(color: result.ok ? Colors.green : tokens.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final ProviderKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.tokens.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        providerKindLabel(kind),
        style: context.textStyles.bodySmall
            ?.copyWith(color: context.tokens.onSurfaceVariant),
      ),
    );
  }
}
