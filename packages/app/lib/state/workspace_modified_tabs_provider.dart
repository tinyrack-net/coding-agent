import 'package:flutter_riverpod/flutter_riverpod.dart';

/// File panels with local edits must remain mounted even when their pane's
/// normal three-tab retention budget is full.
class WorkspaceModifiedTabsNotifier extends Notifier<Set<String>> {
  WorkspaceModifiedTabsNotifier(this.cwd);

  final String cwd;

  @override
  Set<String> build() => const {};

  void setModified(String tabId, {required bool modified}) {
    if (modified == state.contains(tabId)) return;
    state = modified ? {...state, tabId} : ({...state}..remove(tabId));
  }
}

final workspaceModifiedTabsProvider =
    NotifierProvider.family<WorkspaceModifiedTabsNotifier, Set<String>, String>(
      WorkspaceModifiedTabsNotifier.new,
    );
