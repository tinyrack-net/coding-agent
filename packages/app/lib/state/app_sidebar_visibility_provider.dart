import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../mobile_panels/mobile_panel_model.dart';

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

class MobilePanelNotifier extends Notifier<MobilePanelSelection> {
  @override
  MobilePanelSelection build() => const MobilePanelSelection.initial();

  void _setTarget(MobilePanelView target) {
    state = state.setTarget(target);
  }

  void showAgent() => _setTarget(MobilePanelView.agent);

  void showAgentList() => _setTarget(MobilePanelView.agentList);

  void showFileExplorer() => _setTarget(MobilePanelView.fileExplorer);

  void toggleAgentList() => _setTarget(
    state.target == MobilePanelView.agentList
        ? MobilePanelView.agent
        : MobilePanelView.agentList,
  );

  void toggleFileExplorer() => _setTarget(
    state.target == MobilePanelView.fileExplorer
        ? MobilePanelView.agent
        : MobilePanelView.fileExplorer,
  );
}

final mobilePanelProvider =
    NotifierProvider<MobilePanelNotifier, MobilePanelSelection>(
      MobilePanelNotifier.new,
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
