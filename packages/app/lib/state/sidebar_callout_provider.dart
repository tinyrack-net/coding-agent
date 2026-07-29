import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sidebar_callout_state.dart';

const sidebarCalloutDismissalsStorageKey =
    'tinyrack.sidebar-callout-dismissals';

abstract interface class SidebarCalloutStorage {
  Future<String?> load();

  Future<void> save(String value);
}

class SharedPreferencesSidebarCalloutStorage implements SidebarCalloutStorage {
  const SharedPreferencesSidebarCalloutStorage();

  @override
  Future<String?> load() async => (await SharedPreferences.getInstance())
      .getString(sidebarCalloutDismissalsStorageKey);

  @override
  Future<void> save(String value) async {
    await (await SharedPreferences.getInstance()).setString(
      sidebarCalloutDismissalsStorageKey,
      value,
    );
  }
}

final sidebarCalloutStorageProvider = Provider<SidebarCalloutStorage>(
  (_) => const SharedPreferencesSidebarCalloutStorage(),
);

class SidebarCalloutNotifier extends Notifier<SidebarCalloutState> {
  @override
  SidebarCalloutState build() {
    scheduleMicrotask(_loadDismissedKeys);
    return const SidebarCalloutState();
  }

  Future<void> _loadDismissedKeys() async {
    Set<String> dismissedKeys;
    try {
      dismissedKeys = parseDismissedSidebarCalloutKeys(
        await ref.read(sidebarCalloutStorageProvider).load(),
      );
    } catch (_) {
      dismissedKeys = state.dismissedKeys;
    }
    if (!ref.mounted) return;
    state = loadDismissedSidebarCalloutKeys(state, dismissedKeys);
  }

  VoidCallback show(SidebarCalloutOptions options) {
    final result = showSidebarCallout(state, options);
    state = result.state;
    return () {
      if (!ref.mounted) return;
      state = unregisterSidebarCallout(
        state,
        id: options.id,
        token: result.token,
      );
    };
  }

  void dismiss(String id) {
    final result = dismissSidebarCallout(state, id);
    state = result.state;
    if (result.dismissalKey != null) {
      unawaited(
        ref
            .read(sidebarCalloutStorageProvider)
            .save(
              serializeDismissedSidebarCalloutKeys(result.state.dismissedKeys),
            )
            .catchError((_) {}),
      );
    }
    result.dismissedCallout?.options.onDismiss?.call();
  }

  void clear() {
    state = clearSidebarCallouts(state);
  }
}

final sidebarCalloutProvider =
    NotifierProvider<SidebarCalloutNotifier, SidebarCalloutState>(
      SidebarCalloutNotifier.new,
    );

final activeSidebarCalloutProvider = Provider<SidebarCalloutEntry?>(
  (ref) => selectActiveSidebarCallout(ref.watch(sidebarCalloutProvider)),
);
