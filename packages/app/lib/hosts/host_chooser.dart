import 'dart:async';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/daemon_client.dart';
import '../core/host_routes.dart';
import '../core/theme.dart';
import '../state/host_registry_provider.dart';
import '../widgets/host_picker.dart';

typedef HostChooserFilter = bool Function(HostProfile host);
typedef HostChoiceHandler = FutureOr<void> Function(String serverId);

final class ChooseHostInput {
  const ChooseHostInput({
    required this.onChooseHost,
    this.title,
    this.filter,
    this.onNoHosts,
  });

  final String? title;
  final HostChooserFilter? filter;
  final HostChoiceHandler onChooseHost;
  final FutureOr<void> Function()? onNoHosts;
}

final class HostChoiceRequest {
  const HostChoiceRequest({
    required this.id,
    required this.title,
    required this.serverIds,
    required this.onChooseHost,
  });

  final int id;
  final String title;
  final List<String> serverIds;
  final HostChoiceHandler onChooseHost;
}

bool matchesHostChooserQuery(HostProfile host, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return true;
  return host.label.toLowerCase().contains(normalized) ||
      host.serverId.toLowerCase().contains(normalized);
}

String? resolveLocalDaemonServerId(List<HostProfile> hosts) {
  for (final host in hosts) {
    if (host.connections.any(
      (connection) =>
          connection is DirectSocketHostConnection ||
          connection is DirectPipeHostConnection,
    )) {
      return host.serverId;
    }
  }
  for (final host in hosts) {
    if (host.connections.whereType<DirectTcpHostConnection>().any((connection) {
      try {
        return isLoopbackHost(parseHostPort(connection.endpoint).host);
      } on FormatException {
        return false;
      }
    })) {
      return host.serverId;
    }
  }
  return null;
}

class HostChooserController extends Notifier<HostChoiceRequest?> {
  var _nextRequestId = 1;

  @override
  HostChoiceRequest? build() => null;

  bool choose({
    required List<HostProfile> hosts,
    required String? localServerId,
    required ChooseHostInput input,
  }) {
    final filter = input.filter;
    final available = orderHostsLocalFirst(
      hosts,
      localServerId,
    ).where((host) => filter?.call(host) ?? true).toList(growable: false);

    if (available.isEmpty) {
      final onNoHosts = input.onNoHosts;
      if (onNoHosts != null) {
        final result = onNoHosts();
        if (result is Future<void>) unawaited(result);
      }
      return false;
    }
    if (available.length == 1) {
      final result = input.onChooseHost(available.first.serverId);
      if (result is Future<void>) unawaited(result);
      return true;
    }

    state = HostChoiceRequest(
      id: _nextRequestId++,
      title: input.title ?? 'Choose host',
      serverIds: List.unmodifiable(available.map((host) => host.serverId)),
      onChooseHost: input.onChooseHost,
    );
    return true;
  }

  void close() => state = null;

  void select(String serverId) {
    final request = state;
    state = null;
    if (request != null) {
      final result = request.onChooseHost(serverId);
      if (result is Future<void>) unawaited(result);
    }
  }
}

final hostChooserControllerProvider =
    NotifierProvider<HostChooserController, HostChoiceRequest?>(
      HostChooserController.new,
    );

bool openHostChooser(
  BuildContext context,
  WidgetRef ref,
  ChooseHostInput input, {
  String? localServerId,
}) {
  final hosts = ref.read(hostRegistryProvider).hosts;
  final opened = ref
      .read(hostChooserControllerProvider.notifier)
      .choose(
        hosts: hosts,
        localServerId: localServerId ?? resolveLocalDaemonServerId(hosts),
        input: input,
      );
  if (!opened && input.onNoHosts == null) {
    unawaited(
      context.push<void>(
        buildSettingsAddHostRoute(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }
  return opened;
}

class HostChooserHost extends ConsumerWidget {
  const HostChooserHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = ref.watch(hostChooserControllerProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (request != null)
          _HostChooserOverlay(
            key: ValueKey('host-chooser-${request.id}'),
            request: request,
          ),
      ],
    );
  }
}

class _HostChooserOverlay extends ConsumerStatefulWidget {
  const _HostChooserOverlay({super.key, required this.request});

  final HostChoiceRequest request;

  @override
  ConsumerState<_HostChooserOverlay> createState() =>
      _HostChooserOverlayState();
}

class _HostChooserOverlayState extends ConsumerState<_HostChooserOverlay> {
  final _searchController = TextEditingController();
  var _query = '';
  var _activeIndex = 0;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<HostProfile> get _options {
    final hostById = {
      for (final host in ref.read(hostRegistryProvider).hosts)
        host.serverId: host,
    };
    return [
      for (final serverId in widget.request.serverIds)
        if (hostById[serverId] case final HostProfile host
            when matchesHostChooserQuery(host, _query))
          host,
    ];
  }

  int _resolvedActiveIndex(List<HostProfile> options) =>
      options.isEmpty ? 0 : math.min(_activeIndex, options.length - 1);

  void _changeQuery(String value) {
    setState(() {
      _query = value;
      _activeIndex = 0;
    });
  }

  void _moveActive(int delta) {
    final options = _options;
    if (options.isEmpty) return;
    final current = _resolvedActiveIndex(options);
    setState(
      () => _activeIndex = (current + delta + options.length) % options.length,
    );
  }

  void _selectActive() {
    final options = _options;
    if (options.isEmpty) return;
    _select(options[_resolvedActiveIndex(options)].serverId);
  }

  void _select(String serverId) =>
      ref.read(hostChooserControllerProvider.notifier).select(serverId);

  void _close() => ref.read(hostChooserControllerProvider.notifier).close();

  @override
  Widget build(BuildContext context) {
    ref.watch(hostRegistryProvider);
    final options = _options;
    final activeIndex = _resolvedActiveIndex(options);
    final palette = context.paseoPalette;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _moveActive(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _moveActive(-1),
        const SingleActivator(LogicalKeyboardKey.enter): _selectActive,
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          key: const ValueKey('host-chooser'),
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('host-chooser-backdrop'),
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: ColoredBox(color: Colors.black.withValues(alpha: .5)),
            ),
            LayoutBuilder(
              builder: (context, constraints) => Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 48),
                  child: Container(
                    key: const ValueKey('host-chooser-panel'),
                    width: math.min(640, constraints.maxWidth * .92),
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .8,
                    ),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: palette.surface0,
                      border: Border.all(color: palette.border),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x59000000),
                          blurRadius: 24,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: palette.border),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                widget.request.title,
                                style: TextStyle(
                                  color: palette.foreground,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextBox(
                                key: const ValueKey('host-chooser-search'),
                                controller: _searchController,
                                autofocus: true,
                                placeholder: 'Search hosts...',
                                placeholderStyle: TextStyle(
                                  color: palette.foregroundMuted,
                                  fontSize: 18,
                                ),
                                style: TextStyle(
                                  color: palette.foreground,
                                  fontSize: 18,
                                ),
                                padding: EdgeInsets.zero,
                                decoration: const WidgetStatePropertyAll(
                                  BoxDecoration(color: Colors.transparent),
                                ),
                                foregroundDecoration:
                                    const WidgetStatePropertyAll(
                                      BoxDecoration(color: Colors.transparent),
                                    ),
                                onChanged: _changeQuery,
                              ),
                            ],
                          ),
                        ),
                        Flexible(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 420),
                            child: options.isEmpty
                                ? Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 12,
                                      ),
                                      child: Text(
                                        'No matching hosts',
                                        style: TextStyle(
                                          color: palette.foregroundMuted,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    key: const ValueKey('host-chooser-results'),
                                    shrinkWrap: true,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    itemCount: options.length,
                                    itemBuilder: (context, index) =>
                                        _HostChooserRow(
                                          host: options[index],
                                          active: index == activeIndex,
                                          onChooseHost: _select,
                                        ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HostChooserRow extends StatelessWidget {
  const _HostChooserRow({
    required this.host,
    required this.active,
    required this.onChooseHost,
  });

  final HostProfile host;
  final bool active;
  final ValueChanged<String> onChooseHost;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${host.label}, ${host.serverId}',
    child: HoverButton(
      key: ValueKey('host-chooser-row-${host.serverId}'),
      onPressed: () => onChooseHost(host.serverId),
      builder: (context, states) {
        final palette = context.paseoPalette;
        final highlighted =
            active ||
            states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed);
        return Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: highlighted ? palette.surface1 : Colors.transparent,
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: Center(
                  child: HostStatusDotSlot(serverId: host.serverId),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      host.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.foreground, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      host.serverId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.foregroundMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                FluentIcons.server,
                size: 16,
                color: palette.foregroundMuted,
              ),
            ],
          ),
        );
      },
    ),
  );
}
