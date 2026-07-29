import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/host_filter.dart';
import 'package:coding_agent_app/widgets/host_picker.dart';
import 'package:coding_agent_app/widgets/host_status_dot.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports the frozen option ids and label fallbacks', () {
    expect(addHostOptionId, '__add_host__');
    expect(allHostsOptionId, '__all_hosts__');
    expect(enableBuiltInDaemonOptionId, '__enable_built_in_daemon__');
    expect(getHostPickerLabel(_hosts, allHostsOptionId), 'Host');
    expect(
      getHostPickerLabel(_hosts, allHostsOptionId, includeAllHost: true),
      'All hosts',
    );
    expect(
      getHostPickerLabel(_hosts, addHostOptionId, includeAddHost: true),
      'Add host',
    );
    expect(getHostPickerLabel(_hosts, 'remote'), 'Remote');
    expect(
      getHostPickerLabel(_hosts, 'missing', includeAllHost: true),
      'All hosts',
    );
    expect(getHostPickerLabel(_hosts, 'missing'), 'Host');
  });

  test('formats active connections with frozen local and endpoint labels', () {
    expect(
      formatHostPickerConnectionLabel(
        const DirectSocketHostConnection(id: 'socket', path: '/tmp/paseo'),
      ),
      'Local',
    );
    expect(
      formatHostPickerConnectionLabel(
        const DirectPipeHostConnection(id: 'pipe', path: r'\\.\pipe\paseo'),
      ),
      'Local',
    );
    expect(
      formatHostPickerConnectionLabel(
        const DirectTcpHostConnection(id: 'tcp', endpoint: 'example.com:443'),
      ),
      'example.com',
    );
    expect(
      formatHostPickerConnectionLabel(
        const RelayHostConnection(
          id: 'relay',
          relayEndpoint: 'relay.example.com:80',
          daemonPublicKeyB64: 'key',
        ),
      ),
      'relay.example.com',
    );
    expect(
      formatHostPickerConnectionEndpoint('example.com:6767'),
      'example.com:6767',
    );
  });

  test('orders local first and places special options around hosts', () {
    final entries = buildHostPickerEntries(
      hosts: _hosts,
      localServerId: 'local',
      includeAllHost: true,
      includeAddHost: true,
      includeEnableBuiltInDaemon: true,
      showActiveConnection: true,
    );

    expect(entries.map((entry) => entry.id), [
      allHostsOptionId,
      'local',
      'remote',
      addHostOptionId,
      enableBuiltInDaemonOptionId,
    ]);
    expect(entries[1].description, 'localhost:6868');
    expect(entries[2].description, 'remote.example.com');
  });

  testWidgets('picker routes host and special selections independently', (
    tester,
  ) async {
    String? selected;
    var added = 0;
    var enabled = 0;
    await _pump(
      tester,
      HostPicker(
        hosts: _hosts,
        value: allHostsOptionId,
        onSelect: (value) => selected = value,
        includeAllHost: true,
        includeAddHost: true,
        onAddHost: () => added++,
        includeEnableBuiltInDaemon: true,
        onEnableBuiltInDaemon: () => enabled++,
        triggerKey: const ValueKey('host-picker'),
        hostOptionKey: (id) => ValueKey('host-option-$id'),
        addHostKey: const ValueKey('host-option-add'),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('host-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-option-remote')));
    await tester.pumpAndSettle();
    expect(selected, 'remote');

    selected = null;
    await tester.tap(find.byKey(const ValueKey('host-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-option-add')));
    await tester.pumpAndSettle();
    expect(added, 1);
    expect(selected, isNull);

    await tester.tap(find.byKey(const ValueKey('host-picker')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('host-picker-option-__enable_built_in_daemon__'),
      ),
    );
    await tester.pumpAndSettle();
    expect(enabled, 1);
    expect(selected, isNull);
  });

  testWidgets('search appears only above ten hosts', (tester) async {
    await _pump(
      tester,
      HostPicker(
        hosts: _manyHosts(10),
        value: 'host-0',
        onSelect: (_) {},
        searchable: true,
        triggerKey: const ValueKey('ten-hosts'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('ten-hosts')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ten-hosts-search')), findsNothing);
    await tester.tapAt(const Offset(990, 790));
    await tester.pumpAndSettle();

    await _pump(
      tester,
      HostPicker(
        hosts: _manyHosts(11),
        value: 'host-0',
        onSelect: (_) {},
        searchable: true,
        triggerKey: const ValueKey('eleven-hosts'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('eleven-hosts')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('eleven-hosts-search')), findsOneWidget);
    expect(find.widgetWithText(TextBox, 'Search hosts'), findsOneWidget);
  });

  testWidgets('settings action dismisses without selecting the host', (
    tester,
  ) async {
    String? selected;
    String? settingsHost;
    final openStates = <bool>[];
    await _pump(
      tester,
      HostPicker(
        hosts: _hosts,
        value: 'local',
        onSelect: (value) => selected = value,
        onOpenHostSettings: (value) => settingsHost = value,
        onOpenChanged: openStates.add,
        triggerKey: const ValueKey('settings-picker'),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('settings-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-picker-settings-remote')));
    await tester.pumpAndSettle();

    expect(settingsHost, 'remote');
    expect(selected, isNull);
    expect(openStates, [true, false]);
    expect(
      find.byKey(const ValueKey('host-picker-settings-remote')),
      findsNothing,
    );
  });

  testWidgets('shared host filter keeps the frozen pill contract', (
    tester,
  ) async {
    String? selected;
    await _pump(
      tester,
      HostFilter(
        hosts: _hosts,
        selectedHost: allHostsOptionId,
        onSelectHost: (value) => selected = value,
        triggerKey: const ValueKey('host-filter'),
      ),
    );

    final trigger = find.byKey(const ValueKey('host-filter'));
    expect(trigger, findsOneWidget);
    expect(tester.getSize(trigger).height, 32);
    expect(
      find.bySemanticsLabel('Filter: All hosts', skipOffstage: false),
      findsOneWidget,
    );

    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-filter-option-remote')));
    await tester.pumpAndSettle();
    expect(selected, 'remote');
  });

  testWidgets(
    'host status slot is exactly sixteen around the eight-pixel dot',
    (tester) async {
      await _pump(tester, const HostStatusDotSlot(serverId: 'local'));
      expect(
        tester.getSize(find.byType(HostStatusDotSlot)),
        const Size.square(16),
      );
      expect(tester.getSize(find.byType(HostStatusDot)), const Size.square(8));
    },
  );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hostConnectionStateProvider.overrideWith(
          (ref, serverId) => Stream.value(DaemonConnectionState.connected),
        ),
      ],
      child: FluentApp(
        theme: buildAppTheme(),
        home: ScaffoldPage(content: Center(child: child)),
      ),
    ),
  );
  await tester.pump();
}

List<HostProfile> _manyHosts(int count) => [
  for (var index = 0; index < count; index++)
    HostProfile(
      serverId: 'host-$index',
      label: 'Host $index',
      connections: [
        DirectTcpHostConnection(
          id: 'tcp-$index',
          endpoint: 'host-$index.example.com:6868',
        ),
      ],
      preferredConnectionId: 'tcp-$index',
      createdAt: '2026-07-29T00:00:00.000Z',
      updatedAt: '2026-07-29T00:00:00.000Z',
    ),
];

const _hosts = [
  HostProfile(
    serverId: 'remote',
    label: 'Remote',
    connections: [
      DirectTcpHostConnection(
        id: 'remote-tcp',
        endpoint: 'remote.example.com:443',
      ),
    ],
    preferredConnectionId: 'remote-tcp',
    createdAt: '2026-07-29T00:00:00.000Z',
    updatedAt: '2026-07-29T00:00:00.000Z',
  ),
  HostProfile(
    serverId: 'local',
    label: 'Local',
    connections: [
      DirectTcpHostConnection(id: 'local-tcp', endpoint: 'localhost:6868'),
    ],
    preferredConnectionId: 'local-tcp',
    createdAt: '2026-07-29T00:00:00.000Z',
    updatedAt: '2026-07-29T00:00:00.000Z',
  ),
];
