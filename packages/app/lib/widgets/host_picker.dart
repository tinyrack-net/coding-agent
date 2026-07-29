import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';
import 'fluent/select_field.dart';
import 'host_status_dot.dart';

const addHostOptionId = '__add_host__';
const allHostsOptionId = '__all_hosts__';
const enableBuiltInDaemonOptionId = '__enable_built_in_daemon__';
const hostPickerSearchableThreshold = 10;

String getHostPickerLabel(
  List<HostProfile> hosts,
  String value, {
  bool includeAllHost = false,
  bool includeAddHost = false,
}) {
  if (includeAllHost && value == allHostsOptionId) return 'All hosts';
  if (includeAddHost && value == addHostOptionId) return 'Add host';
  for (final host in hosts) {
    if (host.serverId == value) return host.label;
  }
  return includeAllHost ? 'All hosts' : 'Host';
}

String formatHostPickerConnectionEndpoint(String endpoint) =>
    endpoint.replaceFirst(RegExp(r':(?:443|80)$'), '');

String formatHostPickerConnectionLabel(HostConnection connection) =>
    switch (connection) {
      DirectSocketHostConnection() || DirectPipeHostConnection() => 'Local',
      DirectTcpHostConnection(:final endpoint) =>
        formatHostPickerConnectionEndpoint(endpoint),
      RelayHostConnection(:final relayEndpoint) =>
        formatHostPickerConnectionEndpoint(relayEndpoint),
    };

HostConnection? resolveHostPickerActiveConnection(HostProfile host) {
  final preferred = host.preferredConnectionId;
  if (preferred != null) {
    for (final connection in host.connections) {
      if (connection.id == preferred) return connection;
    }
  }
  return host.connections.firstOrNull;
}

enum HostPickerEntryKind { host, all, add, enableBuiltInDaemon }

final class HostPickerEntry {
  const HostPickerEntry({
    required this.id,
    required this.label,
    required this.kind,
    this.host,
    this.description,
  });

  final String id;
  final String label;
  final HostPickerEntryKind kind;
  final HostProfile? host;
  final String? description;
}

List<HostPickerEntry> buildHostPickerEntries({
  required List<HostProfile> hosts,
  String? localServerId,
  bool includeAllHost = false,
  bool includeAddHost = false,
  bool includeEnableBuiltInDaemon = false,
  bool showActiveConnection = false,
}) {
  final ordered = orderHostsLocalFirst(hosts, localServerId);
  return [
    if (includeAllHost)
      const HostPickerEntry(
        id: allHostsOptionId,
        label: 'All hosts',
        kind: HostPickerEntryKind.all,
      ),
    for (final host in ordered)
      HostPickerEntry(
        id: host.serverId,
        label: host.label,
        kind: HostPickerEntryKind.host,
        host: host,
        description: showActiveConnection
            ? switch (resolveHostPickerActiveConnection(host)) {
                final connection? => formatHostPickerConnectionLabel(
                  connection,
                ),
                null => null,
              }
            : null,
      ),
    if (includeAddHost)
      const HostPickerEntry(
        id: addHostOptionId,
        label: 'Add host',
        kind: HostPickerEntryKind.add,
      ),
    if (includeEnableBuiltInDaemon)
      const HostPickerEntry(
        id: enableBuiltInDaemonOptionId,
        label: 'Enable built-in daemon',
        kind: HostPickerEntryKind.enableBuiltInDaemon,
      ),
  ];
}

class HostStatusDotSlot extends StatelessWidget {
  const HostStatusDotSlot({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 16,
    child: Center(child: HostStatusDot(serverId: serverId)),
  );
}

class HostPicker extends StatelessWidget {
  const HostPicker({
    super.key,
    required this.hosts,
    required this.value,
    required this.onSelect,
    this.localServerId,
    this.includeAllHost = false,
    this.includeAddHost = false,
    this.onAddHost,
    this.includeEnableBuiltInDaemon = false,
    this.onEnableBuiltInDaemon,
    this.showActiveConnection = false,
    this.onOpenHostSettings,
    this.searchable = false,
    this.title = 'Host',
    this.desktopPlacement = FlyoutPlacementMode.bottomLeft,
    this.desktopMinWidth,
    this.triggerKey,
    this.hostOptionKey,
    this.addHostKey,
    this.field = false,
    this.size = PaseoFieldControlSize.sm,
    this.disabled = false,
    this.triggerBuilder,
    this.onOpenChanged,
  });

  final List<HostProfile> hosts;
  final String value;
  final ValueChanged<String> onSelect;
  final String? localServerId;
  final bool includeAllHost;
  final bool includeAddHost;
  final VoidCallback? onAddHost;
  final bool includeEnableBuiltInDaemon;
  final VoidCallback? onEnableBuiltInDaemon;
  final bool showActiveConnection;
  final ValueChanged<String>? onOpenHostSettings;
  final bool searchable;
  final String title;
  final FlyoutPlacementMode desktopPlacement;
  final double? desktopMinWidth;
  final Key? triggerKey;
  final Key? Function(String serverId)? hostOptionKey;
  final Key? addHostKey;
  final bool field;
  final PaseoFieldControlSize size;
  final bool disabled;
  final SelectFieldTriggerBuilder? triggerBuilder;
  final ValueChanged<bool>? onOpenChanged;

  @override
  Widget build(BuildContext context) {
    final entries = buildHostPickerEntries(
      hosts: hosts,
      localServerId: localServerId,
      includeAllHost: includeAllHost,
      includeAddHost: includeAddHost,
      includeEnableBuiltInDaemon: includeEnableBuiltInDaemon,
      showActiveConnection: showActiveConnection,
    );
    final selectedEntry = entries
        .where((entry) => entry.id == value)
        .firstOrNull;
    return PaseoSelectField<String>(
      field: field,
      triggerKey: triggerKey,
      label: title,
      value: value,
      selectedDisplay: SelectFieldDisplay(
        label: getHostPickerLabel(
          hosts,
          value,
          includeAllHost: includeAllHost,
          includeAddHost: includeAddHost,
        ),
        description: selectedEntry?.description,
      ),
      options: [
        for (final entry in entries)
          SelectFieldOption(
            id: entry.id,
            value: entry.id,
            label: entry.label,
            description: entry.description,
            optionKey: switch (entry.kind) {
              HostPickerEntryKind.host => hostOptionKey?.call(entry.id),
              HostPickerEntryKind.add => addHostKey,
              _ => null,
            },
          ),
      ],
      onChanged: (id, _) {
        switch (id) {
          case addHostOptionId:
            onAddHost?.call();
          case enableBuiltInDaemonOptionId:
            onEnableBuiltInDaemon?.call();
          default:
            onSelect(id);
        }
      },
      placeholder: includeAllHost ? 'All hosts' : 'Host',
      emptyText: 'No hosts found',
      searchable: searchable && hosts.length > hostPickerSearchableThreshold,
      searchPlaceholder: 'Search hosts',
      title: title,
      size: size,
      disabled: disabled,
      triggerLeading: _entryLeading(selectedEntry),
      triggerBuilder: triggerBuilder,
      onOpenChanged: onOpenChanged,
      desktopPlacement: desktopPlacement,
      desktopMinWidth: desktopMinWidth,
      renderOption: (input) {
        final entry = entries.firstWhere(
          (entry) => entry.id == input.option.id,
        );
        return _HostPickerOption(
          entry: entry,
          selected: input.selected,
          active: input.active,
          onPressed: input.onPressed,
          onDismiss: input.onDismiss,
          onOpenHostSettings: onOpenHostSettings,
        );
      },
    );
  }

  Widget? _entryLeading(HostPickerEntry? entry) => switch (entry?.kind) {
    HostPickerEntryKind.host => HostStatusDotSlot(serverId: entry!.id),
    HostPickerEntryKind.add => const Icon(FluentIcons.add, size: 16),
    HostPickerEntryKind.all || HostPickerEntryKind.enableBuiltInDaemon =>
      const Icon(FluentIcons.server, size: 16),
    null => null,
  };
}

class _HostPickerOption extends StatelessWidget {
  const _HostPickerOption({
    required this.entry,
    required this.selected,
    required this.active,
    required this.onPressed,
    required this.onDismiss,
    required this.onOpenHostSettings,
  });

  final HostPickerEntry entry;
  final bool selected;
  final bool active;
  final VoidCallback onPressed;
  final VoidCallback onDismiss;
  final ValueChanged<String>? onOpenHostSettings;

  @override
  Widget build(BuildContext context) {
    final settings = entry.kind == HostPickerEntryKind.host
        ? onOpenHostSettings
        : null;
    return ListTile(
      tileColor: WidgetStateColor.resolveWith(
        (_) => active ? context.paseoPalette.surface1 : Colors.transparent,
      ),
      shape: const RoundedRectangleBorder(),
      margin: EdgeInsets.zero,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      leading: switch (entry.kind) {
        HostPickerEntryKind.host => HostStatusDotSlot(serverId: entry.id),
        HostPickerEntryKind.add => Icon(
          FluentIcons.add,
          size: 16,
          color: context.paseoPalette.foregroundMuted,
        ),
        HostPickerEntryKind.all ||
        HostPickerEntryKind.enableBuiltInDaemon => Icon(
          FluentIcons.server,
          size: 16,
          color: context.paseoPalette.foregroundMuted,
        ),
      },
      title: Text(entry.label),
      subtitle: entry.description == null ? null : Text(entry.description!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected)
            Icon(
              FluentIcons.check_mark,
              size: 14,
              color: context.paseoPalette.accentBright,
            ),
          if (settings != null)
            Tooltip(
              message: 'Open ${entry.label} settings',
              child: IconButton(
                key: ValueKey('host-picker-settings-${entry.id}'),
                icon: Icon(
                  FluentIcons.settings,
                  size: 16,
                  color: context.paseoPalette.foregroundMuted,
                ),
                onPressed: () {
                  settings(entry.id);
                  onDismiss();
                },
              ),
            ),
        ],
      ),
      onPressed: onPressed,
    );
  }
}
