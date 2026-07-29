import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';

enum SidebarCalloutActionVariant { primary, secondary }

enum SidebarCalloutVariant { defaultVariant, success, error }

@immutable
class SidebarCalloutAction {
  const SidebarCalloutAction({
    required this.label,
    required this.onPressed,
    this.variant = SidebarCalloutActionVariant.secondary,
    this.disabled = false,
    this.testId,
  });

  final String label;
  final VoidCallback onPressed;
  final SidebarCalloutActionVariant variant;
  final bool disabled;
  final String? testId;
}

@immutable
class SidebarCalloutOptions {
  const SidebarCalloutOptions({
    required this.id,
    required this.title,
    this.dismissalKey,
    this.description,
    this.icon,
    this.variant = SidebarCalloutVariant.defaultVariant,
    this.actions = const [],
    this.dismissible = true,
    this.priority = 0,
    this.onDismiss,
    this.testId,
  }) : assert(
         description == null || description is String || description is Widget,
       );

  final String id;
  final String? dismissalKey;
  final String title;
  final Object? description;
  final Widget? icon;
  final SidebarCalloutVariant variant;
  final List<SidebarCalloutAction> actions;
  final bool dismissible;
  final int priority;
  final VoidCallback? onDismiss;
  final String? testId;
}

@immutable
class SidebarCalloutEntry {
  const SidebarCalloutEntry({
    required this.options,
    required this.order,
    required this.token,
  });

  final SidebarCalloutOptions options;
  final int order;
  final int token;

  String get id => options.id;
  int get priority => options.priority;
}

@immutable
class SidebarCalloutState {
  const SidebarCalloutState({
    this.callouts = const [],
    this.dismissedKeys = const {},
    this.dismissalStorageLoaded = false,
    this.nextOrder = 0,
    this.nextToken = 0,
  });

  final List<SidebarCalloutEntry> callouts;
  final Set<String> dismissedKeys;
  final bool dismissalStorageLoaded;
  final int nextOrder;
  final int nextToken;

  SidebarCalloutState copyWith({
    List<SidebarCalloutEntry>? callouts,
    Set<String>? dismissedKeys,
    bool? dismissalStorageLoaded,
    int? nextOrder,
    int? nextToken,
  }) => SidebarCalloutState(
    callouts: callouts ?? this.callouts,
    dismissedKeys: dismissedKeys ?? this.dismissedKeys,
    dismissalStorageLoaded:
        dismissalStorageLoaded ?? this.dismissalStorageLoaded,
    nextOrder: nextOrder ?? this.nextOrder,
    nextToken: nextToken ?? this.nextToken,
  );
}

@immutable
class ShowSidebarCalloutResult {
  const ShowSidebarCalloutResult({required this.state, required this.token});

  final SidebarCalloutState state;
  final int token;
}

@immutable
class DismissSidebarCalloutResult {
  const DismissSidebarCalloutResult({
    required this.state,
    required this.dismissedCallout,
    required this.dismissalKey,
  });

  final SidebarCalloutState state;
  final SidebarCalloutEntry? dismissedCallout;
  final String? dismissalKey;
}

String? normalizeSidebarCalloutDismissalKey(String? key) {
  final trimmed = key?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Set<String> parseDismissedSidebarCalloutKeys(String? value) {
  if (value == null || value.isEmpty) return {};
  try {
    final parsed = jsonDecode(value);
    if (parsed is! List<Object?>) return {};
    return {
      for (final entry in parsed)
        if (entry is String) entry,
    };
  } catch (_) {
    return {};
  }
}

String serializeDismissedSidebarCalloutKeys(Set<String> keys) =>
    jsonEncode(keys.toList(growable: false));

SidebarCalloutState loadDismissedSidebarCalloutKeys(
  SidebarCalloutState state,
  Set<String> dismissedKeys,
) => state.copyWith(
  dismissedKeys: Set.unmodifiable(dismissedKeys),
  dismissalStorageLoaded: true,
);

ShowSidebarCalloutResult showSidebarCallout(
  SidebarCalloutState state,
  SidebarCalloutOptions options,
) {
  final token = state.nextToken + 1;
  final existing = state.callouts
      .where((entry) => entry.id == options.id)
      .firstOrNull;
  final nextEntry = SidebarCalloutEntry(
    options: options,
    order: existing?.order ?? state.nextOrder + 1,
    token: token,
  );
  final callouts = existing == null
      ? [...state.callouts, nextEntry]
      : [
          for (final entry in state.callouts)
            if (entry.id == options.id) nextEntry else entry,
        ];
  return ShowSidebarCalloutResult(
    state: state.copyWith(
      callouts: List.unmodifiable(callouts),
      nextOrder: existing == null ? state.nextOrder + 1 : state.nextOrder,
      nextToken: token,
    ),
    token: token,
  );
}

SidebarCalloutState unregisterSidebarCallout(
  SidebarCalloutState state, {
  required String id,
  required int token,
}) {
  final callouts = state.callouts
      .where((entry) => entry.id != id || entry.token != token)
      .toList(growable: false);
  if (callouts.length == state.callouts.length) return state;
  return state.copyWith(callouts: List.unmodifiable(callouts));
}

DismissSidebarCalloutResult dismissSidebarCallout(
  SidebarCalloutState state,
  String id,
) {
  final dismissed = state.callouts.where((entry) => entry.id == id).firstOrNull;
  final key = normalizeSidebarCalloutDismissalKey(
    dismissed?.options.dismissalKey,
  );
  final dismissedKeys = key == null
      ? state.dismissedKeys
      : Set<String>.unmodifiable({...state.dismissedKeys, key});
  return DismissSidebarCalloutResult(
    state: state.copyWith(
      callouts: List.unmodifiable(
        state.callouts.where((entry) => entry.id != id),
      ),
      dismissedKeys: dismissedKeys,
    ),
    dismissedCallout: dismissed,
    dismissalKey: key,
  );
}

SidebarCalloutState clearSidebarCallouts(SidebarCalloutState state) =>
    state.copyWith(callouts: const []);

SidebarCalloutEntry? selectActiveSidebarCallout(SidebarCalloutState state) {
  final visible = state.callouts.where((entry) {
    final key = normalizeSidebarCalloutDismissalKey(entry.options.dismissalKey);
    return key == null ||
        (state.dismissalStorageLoaded && !state.dismissedKeys.contains(key));
  }).toList();
  if (visible.isEmpty) return null;
  visible.sort(
    (first, second) => second.priority.compareTo(first.priority) != 0
        ? second.priority.compareTo(first.priority)
        : first.order.compareTo(second.order),
  );
  return visible.first;
}
