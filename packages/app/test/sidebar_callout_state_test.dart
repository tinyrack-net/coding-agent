import 'package:coding_agent_app/state/sidebar_callout_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selects highest priority then reveals the next callout', () {
    var state = const SidebarCalloutState();
    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(
        id: 'onboarding',
        priority: 10,
        title: 'Set up scripts',
      ),
    ).state;
    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(
        id: 'update',
        priority: 200,
        title: 'Update available',
      ),
    ).state;

    expect(
      selectActiveSidebarCallout(state)?.options.title,
      'Update available',
    );
    state = dismissSidebarCallout(state, 'update').state;
    expect(selectActiveSidebarCallout(state)?.options.title, 'Set up scripts');
  });

  test('replaces by id while preserving queue order', () {
    var state = const SidebarCalloutState();
    final first = showSidebarCallout(
      state,
      const SidebarCalloutOptions(id: 'daemon', title: 'Old daemon'),
    );
    state = first.state;
    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(id: 'other', title: 'Other'),
    ).state;
    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(id: 'daemon', title: 'New daemon'),
    ).state;

    expect(state.callouts, hasLength(2));
    expect(state.callouts.first.options.title, 'New daemon');
    expect(state.callouts.first.order, 1);
    expect(state.nextOrder, 2);
  });

  test('old registration cannot unregister its replacement', () {
    var state = const SidebarCalloutState();
    final old = showSidebarCallout(
      state,
      const SidebarCalloutOptions(id: 'update', title: 'Old'),
    );
    state = old.state;
    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(id: 'update', title: 'New'),
    ).state;

    state = unregisterSidebarCallout(state, id: 'update', token: old.token);
    expect(selectActiveSidebarCallout(state)?.options.title, 'New');
  });

  test('dismissal key hides matching future callouts', () {
    var state = loadDismissedSidebarCalloutKeys(
      const SidebarCalloutState(),
      {},
    );
    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(
        id: 'update',
        dismissalKey: 'desktop-update:available:1.2.3',
        title: 'Update available',
      ),
    ).state;

    final result = dismissSidebarCallout(state, 'update');
    state = result.state;
    expect(result.dismissalKey, 'desktop-update:available:1.2.3');
    expect(
      serializeDismissedSidebarCalloutKeys(state.dismissedKeys),
      '["desktop-update:available:1.2.3"]',
    );

    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(
        id: 'update',
        dismissalKey: 'desktop-update:available:1.2.3',
        title: 'Dismissed update',
      ),
    ).state;
    expect(selectActiveSidebarCallout(state), isNull);

    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(
        id: 'update',
        dismissalKey: 'desktop-update:available:1.2.4',
        title: 'New update',
      ),
    ).state;
    expect(selectActiveSidebarCallout(state)?.options.title, 'New update');
  });

  test('waits for dismissal storage only for keyed callouts', () {
    var state = const SidebarCalloutState();
    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(
        id: 'update',
        dismissalKey: 'update:1',
        title: 'Update available',
      ),
    ).state;
    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(id: 'ephemeral', title: 'Connected'),
    ).state;

    expect(selectActiveSidebarCallout(state)?.options.title, 'Connected');
    state = unregisterSidebarCallout(
      state,
      id: 'ephemeral',
      token: state.callouts.last.token,
    );
    expect(selectActiveSidebarCallout(state), isNull);

    state = loadDismissedSidebarCalloutKeys(state, {});
    expect(
      selectActiveSidebarCallout(state)?.options.title,
      'Update available',
    );
  });

  test('parses keys defensively and normalizes blank keys', () {
    expect(parseDismissedSidebarCalloutKeys('["a",4,"b"]'), {'a', 'b'});
    expect(parseDismissedSidebarCalloutKeys('{'), isEmpty);
    expect(parseDismissedSidebarCalloutKeys('{"key":"a"}'), isEmpty);
    expect(normalizeSidebarCalloutDismissalKey('  '), isNull);
    expect(normalizeSidebarCalloutDismissalKey(' key '), 'key');
  });

  test('clear preserves dismissal state', () {
    var state = loadDismissedSidebarCalloutKeys(const SidebarCalloutState(), {
      'dismissed',
    });
    state = showSidebarCallout(
      state,
      const SidebarCalloutOptions(id: 'visible', title: 'Visible'),
    ).state;

    state = clearSidebarCallouts(state);
    expect(state.callouts, isEmpty);
    expect(state.dismissedKeys, {'dismissed'});
  });
}
