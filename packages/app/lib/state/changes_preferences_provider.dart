import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ChangesLayout { unified, split }

enum ChangesViewMode { flat, tree }

final class ChangesPreferences {
  const ChangesPreferences({
    this.layout = ChangesLayout.unified,
    this.viewMode = ChangesViewMode.flat,
    this.wrapLines = false,
    this.hideWhitespace = false,
    this.commitsCollapsed = true,
  });

  final ChangesLayout layout;
  final ChangesViewMode viewMode;
  final bool wrapLines;
  final bool hideWhitespace;
  final bool commitsCollapsed;

  ChangesPreferences copyWith({
    ChangesLayout? layout,
    ChangesViewMode? viewMode,
    bool? wrapLines,
    bool? hideWhitespace,
    bool? commitsCollapsed,
  }) => ChangesPreferences(
    layout: layout ?? this.layout,
    viewMode: viewMode ?? this.viewMode,
    wrapLines: wrapLines ?? this.wrapLines,
    hideWhitespace: hideWhitespace ?? this.hideWhitespace,
    commitsCollapsed: commitsCollapsed ?? this.commitsCollapsed,
  );

  factory ChangesPreferences.fromJson(Map<String, Object?> json) =>
      ChangesPreferences(
        layout: _enumOr(
          ChangesLayout.values,
          json['layout'],
          ChangesLayout.unified,
        ),
        viewMode: _enumOr(
          ChangesViewMode.values,
          json['viewMode'],
          ChangesViewMode.flat,
        ),
        wrapLines: json['wrapLines'] is bool
            ? json['wrapLines']! as bool
            : false,
        hideWhitespace: json['hideWhitespace'] is bool
            ? json['hideWhitespace']! as bool
            : false,
        commitsCollapsed: json['commitsCollapsed'] is bool
            ? json['commitsCollapsed']! as bool
            : true,
      );

  Map<String, Object?> toJson() => {
    'layout': layout.name,
    'viewMode': viewMode.name,
    'wrapLines': wrapLines,
    'hideWhitespace': hideWhitespace,
    'commitsCollapsed': commitsCollapsed,
  };
}

abstract interface class ChangesPreferencesStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

final class SharedPreferencesChangesStorage
    implements ChangesPreferencesStorage {
  const SharedPreferencesChangesStorage();

  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String value) async {
    await (await SharedPreferences.getInstance()).setString(key, value);
  }
}

final changesPreferencesStorageProvider = Provider<ChangesPreferencesStorage>(
  (_) => const SharedPreferencesChangesStorage(),
);

final class ChangesPreferencesNotifier
    extends AsyncNotifier<ChangesPreferences> {
  static const storageKey = '@tinyrack:changes-preferences';
  static const legacyWrapLinesKey = 'diff-wrap-lines';

  @override
  Future<ChangesPreferences> build() async {
    final storage = ref.watch(changesPreferencesStorageProvider);
    final encoded = await storage.read(storageKey);
    if (encoded != null) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map) {
          return ChangesPreferences.fromJson(
            Map<String, Object?>.from(decoded),
          );
        }
      } on FormatException {
        // Invalid persisted data is repaired with frozen defaults below.
      }
    }
    final legacyWrapLines = await storage.read(legacyWrapLinesKey);
    final defaults = ChangesPreferences(
      wrapLines: switch (legacyWrapLines) {
        'true' => true,
        'false' => false,
        _ => false,
      },
    );
    await storage.write(storageKey, jsonEncode(defaults.toJson()));
    return defaults;
  }

  Future<void> updatePreferences({
    ChangesLayout? layout,
    ChangesViewMode? viewMode,
    bool? wrapLines,
    bool? hideWhitespace,
    bool? commitsCollapsed,
  }) async {
    final current = state.value ?? const ChangesPreferences();
    final next = current.copyWith(
      layout: layout,
      viewMode: viewMode,
      wrapLines: wrapLines,
      hideWhitespace: hideWhitespace,
      commitsCollapsed: commitsCollapsed,
    );
    state = AsyncData(next);
    await ref
        .read(changesPreferencesStorageProvider)
        .write(storageKey, jsonEncode(next.toJson()));
  }
}

final changesPreferencesProvider =
    AsyncNotifierProvider<ChangesPreferencesNotifier, ChangesPreferences>(
      ChangesPreferencesNotifier.new,
    );

T _enumOr<T extends Enum>(List<T> values, Object? value, T fallback) {
  if (value is! String) return fallback;
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  return fallback;
}
