import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppSidebarVisibilityNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
  void show() => state = true;
  void hide() => state = false;
}

final appSidebarVisibilityProvider =
    NotifierProvider<AppSidebarVisibilityNotifier, bool>(
      AppSidebarVisibilityNotifier.new,
    );
