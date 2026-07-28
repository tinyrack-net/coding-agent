import 'package:coding_agent_app/keyboard/keyboard_action_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispatches by priority and stops at the first handled candidate', () {
    final dispatcher = KeyboardActionDispatcher();
    final calls = <String>[];
    dispatcher.registerHandler(
      KeyboardActionHandler(
        handlerId: 'low',
        actions: const {'action'},
        enabled: true,
        priority: 1,
        handle: (_) {
          calls.add('low');
          return true;
        },
      ),
    );
    dispatcher.registerHandler(
      KeyboardActionHandler(
        handlerId: 'high',
        actions: const {'action'},
        enabled: true,
        priority: 2,
        handle: (_) {
          calls.add('high');
          return false;
        },
      ),
    );

    expect(
      dispatcher.dispatch(
        const KeyboardActionDefinition(
          id: 'action',
          scope: KeyboardActionScope.global,
        ),
      ),
      isTrue,
    );
    expect(calls, ['high', 'low']);
  });

  test('newest registration wins equal priority and replacement is safe', () {
    final dispatcher = KeyboardActionDispatcher();
    final calls = <String>[];
    final disposeFirst = dispatcher.registerHandler(
      KeyboardActionHandler(
        handlerId: 'same',
        actions: const {'action'},
        enabled: true,
        priority: 1,
        handle: (_) {
          calls.add('first');
          return true;
        },
      ),
    );
    final disposeSecond = dispatcher.registerHandler(
      KeyboardActionHandler(
        handlerId: 'same',
        actions: const {'action'},
        enabled: true,
        priority: 1,
        handle: (_) {
          calls.add('second');
          return true;
        },
      ),
    );

    disposeFirst();
    expect(
      dispatcher.dispatch(
        const KeyboardActionDefinition(
          id: 'action',
          scope: KeyboardActionScope.global,
        ),
      ),
      isTrue,
    );
    expect(calls, ['second']);
    disposeSecond();
    expect(
      dispatcher.dispatch(
        const KeyboardActionDefinition(
          id: 'action',
          scope: KeyboardActionScope.global,
        ),
      ),
      isFalse,
    );
  });

  test('filters disabled, inactive, and unrelated handlers', () {
    final dispatcher = KeyboardActionDispatcher();
    for (final handler in [
      KeyboardActionHandler(
        handlerId: 'disabled',
        actions: const {'action'},
        enabled: false,
        priority: 3,
        handle: (_) => true,
      ),
      KeyboardActionHandler(
        handlerId: 'inactive',
        actions: const {'action'},
        enabled: true,
        priority: 2,
        isActive: () => false,
        handle: (_) => true,
      ),
      KeyboardActionHandler(
        handlerId: 'unrelated',
        actions: const {'other'},
        enabled: true,
        priority: 1,
        handle: (_) => true,
      ),
    ]) {
      dispatcher.registerHandler(handler);
    }

    expect(
      dispatcher.dispatch(
        const KeyboardActionDefinition(
          id: 'action',
          scope: KeyboardActionScope.global,
        ),
      ),
      isFalse,
    );
  });

  test('newest handler wins when distinct handlers share a priority', () {
    final dispatcher = KeyboardActionDispatcher();
    final calls = <String>[];
    for (final id in ['older', 'newer']) {
      dispatcher.registerHandler(
        KeyboardActionHandler(
          handlerId: id,
          actions: const {'action'},
          enabled: true,
          priority: 1,
          handle: (_) {
            calls.add(id);
            return true;
          },
        ),
      );
    }

    dispatcher.dispatch(
      const KeyboardActionDefinition(
        id: 'action',
        scope: KeyboardActionScope.global,
      ),
    );
    expect(calls, ['newer']);
  });
}
