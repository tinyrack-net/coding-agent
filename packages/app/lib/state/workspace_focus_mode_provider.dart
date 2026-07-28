import 'package:flutter_riverpod/flutter_riverpod.dart';

class WorkspaceFocusModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void disable() => state = false;
}

final workspaceFocusModeProvider =
    NotifierProvider<WorkspaceFocusModeNotifier, bool>(
      WorkspaceFocusModeNotifier.new,
    );
