import 'dart:async';

import 'package:coding_agent_app/core/agent_hot_route_controller.dart';
import 'package:coding_agent_app/core/desktop/agent_deep_link_source.dart';
import 'package:coding_agent_app/core/desktop/agent_hot_route_binding.dart';
import 'package:coding_agent_app/core/desktop/agent_navigation_inbox.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('subscribes before marking the controller ready', (tester) async {
    final order = <String>[];
    final source = _FakeSource(onListen: () => order.add('listen'));
    final routes = <String>[];
    final controller = _RecordingController(
      routes: routes,
      onNavigate: (_) => order.add('navigate'),
    );

    await tester.pumpWidget(_binding(source: source, controller: controller));

    expect(source.listenCount, 1);
    expect(order, ['listen']);
    expect(routes, isEmpty);

    source.emit('coding-agent://h/server/agent/agent-1');
    expect(routes, ['/h/server/agent/agent-1']);
  });

  testWidgets('keeps only the newest event delivered during bootstrap', (
    tester,
  ) async {
    final listenCompleter = Completer<void>();
    final source = _FakeSource(
      beforeListenCompletes: (emit) async {
        emit('coding-agent://h/server/agent/agent-1');
        emit('coding-agent://h/server/agent/agent-2');
        await listenCompleter.future;
      },
    );
    final routes = <String>[];
    final controller = _RecordingController(routes: routes);

    await tester.pumpWidget(_binding(source: source, controller: controller));
    await tester.pump();
    expect(routes, isEmpty);

    listenCompleter.complete();
    await tester.pump();

    expect(routes, ['/h/server/agent/agent-2']);
  });

  testWidgets('does not replay a cold initial location', (tester) async {
    final source = _FakeSource();
    final routes = <String>['/h/server/agent/cold-agent'];
    final controller = _RecordingController(routes: routes);

    await tester.pumpWidget(_binding(source: source, controller: controller));
    await tester.pump();

    expect(routes, ['/h/server/agent/cold-agent']);
    expect(source.listenCount, 1);
  });

  testWidgets('cancels the source before disposing the controller', (
    tester,
  ) async {
    final order = <String>[];
    final controller = _RecordingController(routes: []);
    final source = _FakeSource(
      onCancel: () {
        final disposition = controller.controller.receiveUri(
          'coding-agent://h/server/agent/during-cancel',
        );
        order.add(
          disposition == AgentHotRouteDisposition.navigated
              ? 'cancel-before-dispose'
              : 'cancel-after-dispose',
        );
      },
    );

    await tester.pumpWidget(_binding(source: source, controller: controller));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(order, ['cancel-before-dispose']);
    source.emit('coding-agent://h/server/agent/agent-1');
    expect(
      controller.controller.receiveUri(
        'coding-agent://h/server/agent/after-dispose',
      ),
      AgentHotRouteDisposition.ignored,
    );
  });

  testWidgets('registration failure retries without overlapping listeners', (
    tester,
  ) async {
    final source = _FakeSource(failuresBeforeSuccess: 1);
    final routes = <String>[];
    final controller = _RecordingController(routes: routes);

    await tester.pumpWidget(
      _binding(
        source: source,
        controller: controller,
        retryDelay: const Duration(milliseconds: 20),
      ),
    );
    await tester.pump();
    expect(source.listenCount, 1);
    expect(source.activeListeners, 0);

    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(source.listenCount, 2);
    expect(source.maxActiveListeners, 1);

    source.emit('coding-agent://h/server/agent/agent-2');
    expect(routes, ['/h/server/agent/agent-2']);
  });

  testWidgets('dispose cancels a pending retry', (tester) async {
    final source = _FakeSource(failuresBeforeSuccess: 10);
    final controller = _RecordingController(routes: []);

    await tester.pumpWidget(
      _binding(
        source: source,
        controller: controller,
        retryDelay: const Duration(milliseconds: 20),
      ),
    );
    await tester.pump();
    expect(source.listenCount, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 40));

    expect(source.listenCount, 1);
  });
}

Widget _binding({
  required _FakeSource source,
  required _RecordingController controller,
  Duration retryDelay = const Duration(seconds: 1),
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: AgentHotRouteBinding(
    source: source,
    controller: controller.controller,
    retryDelay: retryDelay,
    child: const SizedBox(key: ValueKey('child')),
  ),
);

final class _RecordingController {
  _RecordingController({required this.routes, this.onNavigate}) {
    controller = AgentHotRouteController(
      inbox: AgentNavigationInbox(),
      windowId: 1,
      navigate: (route) {
        routes.add(route);
        onNavigate?.call(route);
      },
    );
  }

  final List<String> routes;
  final void Function(String route)? onNavigate;
  late final AgentHotRouteController controller;
}

final class _FakeSource implements AgentDeepLinkSource {
  _FakeSource({
    this.onListen,
    this.onCancel,
    this.beforeListenCompletes,
    this.failuresBeforeSuccess = 0,
  });

  final VoidCallback? onListen;
  final VoidCallback? onCancel;
  final Future<void> Function(void Function(String uri) emit)?
  beforeListenCompletes;
  final int failuresBeforeSuccess;

  AgentDeepLinkHandler? _handler;
  var listenCount = 0;
  var activeListeners = 0;
  var maxActiveListeners = 0;

  @override
  Future<AgentDeepLinkSubscription> listen(AgentDeepLinkHandler onUri) async {
    listenCount += 1;
    onListen?.call();
    if (listenCount <= failuresBeforeSuccess) {
      throw StateError('registration failed');
    }
    activeListeners += 1;
    if (activeListeners > maxActiveListeners) {
      maxActiveListeners = activeListeners;
    }
    _handler = onUri;
    await beforeListenCompletes?.call(onUri);
    return _FakeSubscription(() {
      if (identical(_handler, onUri)) _handler = null;
      activeListeners -= 1;
      onCancel?.call();
    });
  }

  void emit(String uri) => _handler?.call(uri);
}

final class _FakeSubscription implements AgentDeepLinkSubscription {
  _FakeSubscription(this._onCancel);

  final VoidCallback _onCancel;
  var _cancelled = false;

  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel();
  }
}
