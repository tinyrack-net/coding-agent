/// Port of Paseo 0.2.0's `keyboard/keyboard-shortcut-routing.ts` and
/// `components/ui/combobox-keyboard.ts`.
///
/// Both upstream modules are tiny pure guards that decide whether — and where —
/// a keypress is allowed to land, kept outside their widgets so the decision is
/// testable without mounting anything:
///
/// * [canToggleFileExplorerShortcut] gates the file-explorer toggle shortcut.
///   The explorer only exists on host workspace and host agent routes, so the
///   shortcut must stay inert everywhere else (settings, sessions, the host
///   index) rather than firing a handler that has no panel to act on. It is
///   route-shape driven, not selection driven: `selectedAgentId` is accepted for
///   call-site parity but deliberately unused, because a workspace route with no
///   agent selected still owns an explorer.
/// * [getNextActiveIndex] resolves arrow-key movement inside a combobox
///   listbox. It wraps at both ends, treats "nothing active yet" (`-1`) as
///   entering from the matching edge, and normalizes an out-of-range index
///   against the current item count so a list that shrank under the cursor still
///   moves somewhere valid instead of landing off the end.
///
/// This library only adds what the repo's existing keyboard layer was missing.
/// Shortcut matching (`shortcut_engine.dart`), action dispatch
/// (`keyboard_action_dispatcher.dart`), and the global route-level shortcut
/// router (`shortcut_routing.dart`) already cover the rest of Paseo's keyboard
/// pipeline.
library;

import '../core/host_routes.dart';

/// Vertical arrow keys a combobox listbox responds to.
///
/// Upstream types this as the `"ArrowDown" | "ArrowUp"` string union taken
/// straight off the DOM `KeyboardEvent`; Dart models it as a closed enum.
enum ComboboxArrowKey { down, up }

/// Whether the file-explorer toggle shortcut should run for the current route.
///
/// [toggleFileExplorer] is the handler the shortcut would invoke; a null handler
/// means the surface has no explorer wired up at all, which short-circuits ahead
/// of any route check. [selectedAgentId] mirrors upstream's parameter and is
/// intentionally ignored — see the library doc.
bool canToggleFileExplorerShortcut({
  required String pathname,
  void Function()? toggleFileExplorer,
  String? selectedAgentId,
}) {
  if (toggleFileExplorer == null) return false;
  if (parseHostWorkspaceRouteFromPathname(pathname) != null) return true;
  if (parseHostAgentRouteFromPathname(pathname) != null) return true;
  return false;
}

/// Index the combobox should activate after [key], or `-1` when there is
/// nothing to activate.
///
/// [currentIndex] is negative when no item is active yet.
int getNextActiveIndex({
  required int currentIndex,
  required int itemCount,
  required ComboboxArrowKey key,
}) {
  if (itemCount <= 0) return -1;

  if (currentIndex < 0) {
    return key == ComboboxArrowKey.down ? 0 : itemCount - 1;
  }

  // Guards against a stale index left over from a longer list.
  final normalizedCurrent = currentIndex % itemCount;
  return key == ComboboxArrowKey.down
      ? (normalizedCurrent + 1) % itemCount
      : (normalizedCurrent - 1 + itemCount) % itemCount;
}
