enum KeyboardActionScope { global, messageInput, sidebar, workspace }

final class KeyboardActionDefinition {
  const KeyboardActionDefinition({
    required this.id,
    required this.scope,
    this.index,
    this.delta,
  });

  final String id;
  final KeyboardActionScope scope;
  final int? index;
  final int? delta;
}

typedef KeyboardActionCallback = bool Function(KeyboardActionDefinition action);

final class KeyboardActionHandler {
  const KeyboardActionHandler({
    required this.handlerId,
    required this.actions,
    required this.enabled,
    required this.priority,
    required this.handle,
    this.isActive,
  });

  final String handlerId;
  final Set<String> actions;
  final bool enabled;
  final int priority;
  final bool Function()? isActive;
  final KeyboardActionCallback handle;
}

final class _RegisteredKeyboardActionHandler {
  const _RegisteredKeyboardActionHandler({
    required this.handler,
    required this.registeredAt,
  });

  final KeyboardActionHandler handler;
  final int registeredAt;
}

final class KeyboardActionDispatcher {
  final _handlers = <String, _RegisteredKeyboardActionHandler>{};
  var _nextRegistrationOrder = 1;

  void Function() registerHandler(KeyboardActionHandler handler) {
    final registration = _RegisteredKeyboardActionHandler(
      handler: handler,
      registeredAt: _nextRegistrationOrder++,
    );
    _handlers[handler.handlerId] = registration;
    return () {
      if (identical(_handlers[handler.handlerId], registration)) {
        _handlers.remove(handler.handlerId);
      }
    };
  }

  bool dispatch(KeyboardActionDefinition action) {
    final candidates =
        _handlers.values
            .where((entry) => entry.handler.actions.contains(action.id))
            .where((entry) => entry.handler.enabled)
            .where((entry) => entry.handler.isActive?.call() ?? true)
            .toList()
          ..sort((left, right) {
            final priority = right.handler.priority.compareTo(
              left.handler.priority,
            );
            return priority != 0
                ? priority
                : right.registeredAt.compareTo(left.registeredAt);
          });
    for (final candidate in candidates) {
      if (candidate.handler.handle(action)) return true;
    }
    return false;
  }
}

final keyboardActionDispatcher = KeyboardActionDispatcher();
