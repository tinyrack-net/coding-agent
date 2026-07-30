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

class MobileSidebarVisibilityNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void show() => state = true;
  void hide() => state = false;
}

final mobileSidebarVisibilityProvider =
    NotifierProvider<MobileSidebarVisibilityNotifier, bool>(
      MobileSidebarVisibilityNotifier.new,
    );

class AppCompactLayoutNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setCompact(bool compact) {
    if (state != compact) state = compact;
  }
}

final appCompactLayoutProvider =
    NotifierProvider<AppCompactLayoutNotifier, bool>(
      AppCompactLayoutNotifier.new,
    );
