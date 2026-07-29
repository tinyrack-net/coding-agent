import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/hosts/host_chooser.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matches trimmed query against label and server id', () {
    expect(matchesHostChooserQuery(_remoteHost, ''), isTrue);
    expect(matchesHostChooserQuery(_remoteHost, '  REMOTE  '), isTrue);
    expect(matchesHostChooserQuery(_remoteHost, 'SERVER-REMOTE'), isTrue);
    expect(matchesHostChooserQuery(_remoteHost, 'missing'), isFalse);
  });

  test('resolves local socket, pipe, then loopback hosts', () {
    expect(
      resolveLocalDaemonServerId([
        _remoteHost,
        _host(
          id: 'socket',
          label: 'Socket',
          connection: const DirectSocketHostConnection(
            id: 'socket-path',
            path: '/tmp/paseo.sock',
          ),
        ),
      ]),
      'socket',
    );
    expect(
      resolveLocalDaemonServerId([
        _remoteHost,
        _host(
          id: 'pipe',
          label: 'Pipe',
          connection: const DirectPipeHostConnection(
            id: 'pipe-path',
            path: r'\\.\pipe\paseo',
          ),
        ),
      ]),
      'pipe',
    );
    expect(resolveLocalDaemonServerId(_hosts), 'server-local');
    expect(resolveLocalDaemonServerId([_remoteHost]), isNull);
  });

  test(
    'controller preserves frozen zero, one, and many-host branches',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(hostChooserControllerProvider.notifier);
      var noHosts = 0;
      String? selected;

      expect(
        controller.choose(
          hosts: const [],
          localServerId: null,
          input: ChooseHostInput(
            onChooseHost: (value) => selected = value,
            onNoHosts: () => noHosts++,
          ),
        ),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(noHosts, 1);
      expect(selected, isNull);
      expect(container.read(hostChooserControllerProvider), isNull);

      expect(
        controller.choose(
          hosts: [_remoteHost],
          localServerId: null,
          input: ChooseHostInput(onChooseHost: (value) => selected = value),
        ),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(selected, 'server-remote');
      expect(container.read(hostChooserControllerProvider), isNull);

      selected = null;
      expect(
        controller.choose(
          hosts: _hosts,
          localServerId: 'server-local',
          input: ChooseHostInput(
            title: 'Import from host',
            onChooseHost: (value) => selected = value,
          ),
        ),
        isTrue,
      );
      final request = container.read(hostChooserControllerProvider);
      expect(request?.title, 'Import from host');
      expect(request?.serverIds, ['server-local', 'server-remote']);
      expect(selected, isNull);

      controller.select('server-remote');
      expect(container.read(hostChooserControllerProvider), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(selected, 'server-remote');
    },
  );

  test(
    'controller filters before applying zero and one-host behavior',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(hostChooserControllerProvider.notifier);
      String? selected;

      final opened = controller.choose(
        hosts: _hosts,
        localServerId: 'server-local',
        input: ChooseHostInput(
          filter: (host) => host.serverId == 'server-remote',
          onChooseHost: (value) => selected = value,
        ),
      );

      expect(opened, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(selected, 'server-remote');
      expect(container.read(hostChooserControllerProvider), isNull);
    },
  );

  testWidgets('multiple hosts render frozen order and panel geometry', (
    tester,
  ) async {
    final container = await _pumpChooser(tester);
    _openMultiple(container);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('host-chooser')), findsOneWidget);
    expect(find.text('Choose host'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-chooser-search')), findsOneWidget);
    final panel = tester.getRect(
      find.byKey(const ValueKey('host-chooser-panel')),
    );
    expect(panel.width, 640);
    expect(panel.top, 48);

    final local = tester.getRect(
      find.byKey(const ValueKey('host-chooser-row-server-local')),
    );
    final remote = tester.getRect(
      find.byKey(const ValueKey('host-chooser-row-server-remote')),
    );
    expect(local.height, greaterThanOrEqualTo(56));
    expect(remote.height, greaterThanOrEqualTo(56));
    expect(local.top, lessThan(remote.top));
  });

  testWidgets('search matches label and id and reports the frozen empty copy', (
    tester,
  ) async {
    final container = await _pumpChooser(tester);
    _openMultiple(container);
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('host-chooser-search'));

    await tester.enterText(search, 'SERVER-REMOTE');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('host-chooser-row-server-local')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('host-chooser-row-server-remote')),
      findsOneWidget,
    );

    await tester.enterText(search, 'missing');
    await tester.pump();
    expect(find.text('No matching hosts'), findsOneWidget);
  });

  testWidgets('keyboard wraps, selects, and closes before callback', (
    tester,
  ) async {
    final container = await _pumpChooser(tester);
    String? selected;
    var closedBeforeCallback = false;
    _openMultiple(
      container,
      onChooseHost: (value) {
        selected = value;
        closedBeforeCallback =
            container.read(hostChooserControllerProvider) == null;
      },
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(selected, 'server-remote');
    expect(closedBeforeCallback, isTrue);
    expect(find.byKey(const ValueKey('host-chooser')), findsNothing);
  });

  testWidgets('Escape and backdrop dismiss without choosing', (tester) async {
    final container = await _pumpChooser(tester);
    String? selected;
    _openMultiple(container, onChooseHost: (value) => selected = value);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host-chooser')), findsNothing);
    expect(selected, isNull);

    _openMultiple(container, onChooseHost: (value) => selected = value);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host-chooser')), findsNothing);
    expect(selected, isNull);
  });

  testWidgets('removed request hosts disappear while the chooser is open', (
    tester,
  ) async {
    final registry = _MutableRegistry(_hosts);
    final container = await _pumpChooser(tester, registry: registry);
    _openMultiple(container);
    await tester.pumpAndSettle();

    registry.replace([_localHost]);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('host-chooser-row-server-local')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('host-chooser-row-server-remote')),
      findsNothing,
    );
  });

  testWidgets('zero-host helper invokes the caller override without opening', (
    tester,
  ) async {
    var noHosts = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(() => _MutableRegistry(const [])),
        ],
        child: FluentApp(
          theme: buildAppTheme(),
          home: _OpenChooserButton(onNoHosts: () => noHosts++),
        ),
      ),
    );

    await tester.tap(find.text('Open chooser'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(noHosts, 1);
    expect(find.byKey(const ValueKey('host-chooser')), findsNothing);
  });
}

Future<ProviderContainer> _pumpChooser(
  WidgetTester tester, {
  _MutableRegistry? registry,
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      hostRegistryProvider.overrideWith(
        () => registry ?? _MutableRegistry(_hosts),
      ),
      hostConnectionStateProvider.overrideWith(
        (ref, serverId) => Stream.value(DaemonConnectionState.connected),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        theme: buildAppTheme(),
        home: const HostChooserHost(
          child: ColoredBox(
            color: Colors.transparent,
            child: SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
  return container;
}

void _openMultiple(
  ProviderContainer container, {
  HostChoiceHandler? onChooseHost,
}) {
  container
      .read(hostChooserControllerProvider.notifier)
      .choose(
        hosts: _hosts,
        localServerId: 'server-local',
        input: ChooseHostInput(onChooseHost: onChooseHost ?? (_) {}),
      );
}

class _OpenChooserButton extends ConsumerWidget {
  const _OpenChooserButton({required this.onNoHosts});

  final VoidCallback onNoHosts;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Button(
    onPressed: () => openHostChooser(
      context,
      ref,
      ChooseHostInput(onChooseHost: (_) {}, onNoHosts: onNoHosts),
    ),
    child: const Text('Open chooser'),
  );
}

class _MutableRegistry extends HostRegistryNotifier {
  _MutableRegistry(this.hosts);

  List<HostProfile> hosts;

  @override
  HostRegistryState build() => HostRegistryState(
    hosts: hosts,
    activeServerId: hosts.firstOrNull?.serverId,
    loaded: true,
  );

  void replace(List<HostProfile> value) {
    hosts = value;
    state = HostRegistryState(
      hosts: value,
      activeServerId: value.firstOrNull?.serverId,
      loaded: true,
    );
  }
}

HostProfile _host({
  required String id,
  required String label,
  required HostConnection connection,
}) => HostProfile(
  serverId: id,
  label: label,
  connections: [connection],
  preferredConnectionId: connection.id,
  createdAt: '2026-07-29T00:00:00.000Z',
  updatedAt: '2026-07-29T00:00:00.000Z',
);

final _remoteHost = _host(
  id: 'server-remote',
  label: 'Remote',
  connection: const DirectTcpHostConnection(
    id: 'remote-tcp',
    endpoint: 'remote.example.com:443',
  ),
);

final _localHost = _host(
  id: 'server-local',
  label: 'Local',
  connection: const DirectTcpHostConnection(
    id: 'local-tcp',
    endpoint: '127.0.0.1:6868',
  ),
);

final _hosts = [_remoteHost, _localHost];
