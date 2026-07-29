import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/external_url_launcher.dart';
import '../providers/acp_provider_catalog.dart';
import '../providers/acp_provider_catalog_data.dart';
import '../providers/providers_snapshot.dart';
import '../state/daemon_config_provider.dart';
import '../state/daemon_providers.dart';
import '../state/providers_snapshot_provider.dart';
import '../widgets/provider_catalog_list.dart';
import '../widgets/provider_icon.dart';
import '../widgets/provider_settings_sheet.dart';

class HostProvidersSettingsSection extends ConsumerStatefulWidget {
  const HostProvidersSettingsSection({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<HostProvidersSettingsSection> createState() =>
      _HostProvidersSettingsSectionState();
}

class _HostProvidersSettingsSectionState
    extends ConsumerState<HostProvidersSettingsSection> {
  String? _installingProviderId;
  String? _pendingProviderId;
  String? _removingProviderId;
  String? _error;

  ProvidersSnapshotScope _scope() => ProvidersSnapshotScope(
    client: ref.read(daemonClientProvider),
    serverId: widget.serverId,
  );

  Future<void> _install(AcpProviderCatalogEntry entry) async {
    if (_installingProviderId != null) return;
    setState(() {
      _installingProviderId = entry.id;
      _error = null;
    });
    try {
      await ref
          .read(daemonConfigProvider.notifier)
          .patch(buildAcpProviderConfigPatch(entry));
      await ref.read(providersSnapshotProvider(_scope()).notifier).refresh([
        entry.id,
      ]);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _installingProviderId = null);
    }
  }

  Future<void> _toggle(ProviderSnapshotEntry entry, bool enabled) async {
    if (_pendingProviderId != null) return;
    setState(() {
      _pendingProviderId = entry.provider;
      _error = null;
    });
    try {
      final current = ref
          .read(daemonConfigProvider)
          .value
          ?.providers[entry.provider];
      await ref
          .read(daemonConfigProvider.notifier)
          .patch(
            MutableDaemonConfigPatch(
              providers: {
                entry.provider: MutableDaemonProviderConfig(
                  enabled: enabled,
                  additionalModels: current?.additionalModels,
                  extra: current?.extra ?? const {},
                ),
              },
            ),
          );
      await ref.read(providersSnapshotProvider(_scope()).notifier).refresh([
        entry.provider,
      ]);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _pendingProviderId = null);
    }
  }

  Future<void> _remove(ProviderSnapshotEntry entry) async {
    if (_removingProviderId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('Remove ${entry.label ?? entry.provider}?'),
        content: const Text(
          'This removes the custom provider from the host configuration.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _removingProviderId = entry.provider;
      _error = null;
    });
    try {
      await ref
          .read(daemonConfigProvider.notifier)
          .patch(MutableDaemonConfigPatch(removeProviders: [entry.provider]));
      await ref.read(providersSnapshotProvider(_scope()).notifier).refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _removingProviderId = null);
    }
  }

  Future<void> _openInstructions(AcpProviderCatalogEntry entry) async {
    final opened = await ref
        .read(externalUrlLauncherProvider)
        .open(entry.installLink);
    if (!opened && mounted) {
      setState(() => _error = 'Unable to open ${entry.installLink}');
    }
  }

  Future<void> _openProviderSettings(ProviderSnapshotEntry entry) =>
      showProviderSettingsSheet(
        context: context,
        serverId: widget.serverId,
        provider: entry.provider,
      );

  @override
  Widget build(BuildContext context) {
    final scope = ProvidersSnapshotScope(
      client: ref.watch(daemonClientProvider),
      serverId: widget.serverId,
    );
    final snapshot = ref.watch(providersSnapshotProvider(scope));
    final entries = snapshot.entries ?? const <ProviderSnapshotEntry>[];
    final installedIds = {for (final entry in entries) entry.provider};

    return ScaffoldPage(
      header: const PageHeader(title: Text('Providers')),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (_error != null) ...[
                InfoBar(
                  title: const Text('Unable to update providers'),
                  content: Text(_error!),
                  severity: InfoBarSeverity.error,
                ),
                const SizedBox(height: 12),
              ],
              Text(
                'Providers',
                style: FluentTheme.of(context).typography.subtitle,
              ),
              const SizedBox(height: 8),
              if (!snapshot.supportsSnapshot)
                const Card(
                  child: Text('This host does not support provider discovery.'),
                )
              else if (snapshot.isLoading && snapshot.entries == null)
                const Card(
                  child: SizedBox(
                    height: 72,
                    child: Center(child: ProgressRing()),
                  ),
                )
              else if (snapshot.error != null && snapshot.entries == null)
                Card(child: Text(snapshot.error!))
              else if (entries.isEmpty)
                const Card(child: Text('No providers configured.'))
              else
                Card(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var index = 0; index < entries.length; index++) ...[
                        if (index > 0) const Divider(),
                        _InstalledProviderRow(
                          entry: entries[index],
                          pending:
                              _pendingProviderId == entries[index].provider,
                          removing:
                              _removingProviderId == entries[index].provider,
                          onToggle: (enabled) =>
                              _toggle(entries[index], enabled),
                          onOpen: () => _openProviderSettings(entries[index]),
                          onRemove: entries[index].source == 'custom'
                              ? () => _remove(entries[index])
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 24),
              Text(
                'Add provider',
                style: FluentTheme.of(context).typography.subtitle,
              ),
              const SizedBox(height: 8),
              ProviderCatalogList(
                entries: acpProviderCatalog,
                installedProviderIds: installedIds,
                installingProviderId: _installingProviderId,
                onInstall: _install,
                onOpenInstallInstructions: _openInstructions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstalledProviderRow extends StatelessWidget {
  const _InstalledProviderRow({
    required this.entry,
    required this.pending,
    required this.removing,
    required this.onToggle,
    required this.onOpen,
    required this.onRemove,
  });

  final ProviderSnapshotEntry entry;
  final bool pending;
  final bool removing;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final status = _providerStatus(entry);
    return Semantics(
      button: true,
      label: '${entry.label ?? entry.provider} provider details',
      child: HoverButton(
        key: ValueKey('installed-provider-${entry.provider}'),
        onPressed: onOpen,
        builder: (context, states) => Container(
          color: states.contains(WidgetState.pressed)
              ? FluentTheme.of(context).resources.subtleFillColorSecondary
              : states.contains(WidgetState.hovered)
              ? FluentTheme.of(context).resources.subtleFillColorTertiary
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(FluentIcons.chevron_right, size: 12),
              const SizedBox(width: 8),
              ProviderIcon(
                provider: entry.provider,
                size: 20,
                color:
                    FluentTheme.of(context).typography.body?.color ??
                    Colors.white,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.label ?? entry.provider),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: status.$2,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          status.$1,
                          style: FluentTheme.of(context).typography.caption,
                        ),
                        if (entry.models?.isNotEmpty == true) ...[
                          const SizedBox(width: 6),
                          Text(
                            '· ${entry.models!.length} models',
                            style: FluentTheme.of(context).typography.caption,
                          ),
                        ],
                      ],
                    ),
                    if (entry.error != null)
                      Text(
                        entry.error!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FluentTheme.of(context).typography.caption,
                      ),
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  key: ValueKey('remove-provider-${entry.provider}'),
                  icon: removing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: ProgressRing(strokeWidth: 2),
                        )
                      : const Icon(FluentIcons.delete, size: 16),
                  onPressed: removing ? null : onRemove,
                ),
              ToggleSwitch(
                key: ValueKey('toggle-provider-${entry.provider}'),
                checked: entry.enabled,
                onChanged: pending ? null : onToggle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

(String, Color) _providerStatus(ProviderSnapshotEntry entry) {
  if (!entry.enabled) return ('Disabled', Colors.grey);
  return switch (entry.status) {
    ProviderCatalogStatus.loading => ('Loading', Colors.blue),
    ProviderCatalogStatus.ready => ('Available', Colors.green),
    ProviderCatalogStatus.error => ('Error', Colors.red),
    ProviderCatalogStatus.unavailable => ('Not installed', Colors.orange),
  };
}
