import 'package:flutter/widgets.dart';

import 'shortcut_engine.dart';

class ShortcutFocusScope extends InheritedWidget {
  const ShortcutFocusScope({
    super.key,
    required this.scope,
    required super.child,
  });

  final KeyboardFocusScope scope;

  static KeyboardFocusScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ShortcutFocusScope>()?.scope;

  @override
  bool updateShouldNotify(ShortcutFocusScope oldWidget) =>
      oldWidget.scope != scope;
}
