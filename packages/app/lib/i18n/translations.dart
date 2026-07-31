/// Port of Paseo 0.2.0's `i18n/i18next.ts` and `i18n/resources/*`.
///
/// Upstream ships i18next with one nested resource object per locale.
/// Flutter has no i18next, so the same frozen resource trees are vendored
/// as JSON assets (`assets/i18n/<locale>.json`, generated from the frozen
/// `.ts` resources) and read through this minimal translator, which
/// reproduces the parts of i18next the app actually uses: dotted key
/// lookup, `{{name}}` interpolation, and fallback to English for a key a
/// locale is missing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'locales.dart';

/// Loads a locale's raw JSON. Injectable so tests do not need the asset
/// bundle.
typedef TranslationLoader = Future<String> Function(SupportedLocale locale);

Future<String> _loadFromAssets(SupportedLocale locale) =>
    rootBundle.loadString('assets/i18n/${locale.code}.json');

/// One locale's flattened `a.b.c` -> value table.
final class TranslationTable {
  const TranslationTable(this.locale, this._values);

  final SupportedLocale locale;
  final Map<String, String> _values;

  String? operator [](String key) => _values[key];

  int get length => _values.length;

  Iterable<String> get keys => _values.keys;

  /// Flattens the frozen nested resource tree into dotted keys, which is
  /// how every call site addresses them.
  factory TranslationTable.fromJson(
    SupportedLocale locale,
    Map<String, Object?> json,
  ) {
    final values = <String, String>{};
    void walk(Map<String, Object?> node, String prefix) {
      for (final entry in node.entries) {
        final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
        final value = entry.value;
        if (value is Map<String, Object?>) {
          walk(value, key);
        } else if (value is String) {
          values[key] = value;
        }
      }
    }

    walk(json, '');
    return TranslationTable(locale, values);
  }
}

/// The app's translator.
///
/// Missing keys return the key itself rather than throwing or rendering
/// blank, matching i18next: a missing string shows up as an obviously wrong
/// label instead of an invisible gap or a crash.
class Translations {
  Translations._(this._active, this._fallback);

  final TranslationTable _active;
  final TranslationTable? _fallback;

  SupportedLocale get locale => _active.locale;

  /// Loads [locale] plus the English fallback.
  static Future<Translations> load(
    SupportedLocale locale, {
    TranslationLoader loader = _loadFromAssets,
  }) async {
    final active = await _loadTable(locale, loader);
    if (locale == defaultLocale) return Translations._(active, null);
    final fallback = await _loadTable(defaultLocale, loader);
    return Translations._(active, fallback);
  }

  static Future<TranslationTable> _loadTable(
    SupportedLocale locale,
    TranslationLoader loader,
  ) async {
    final raw = await loader(locale);
    return TranslationTable.fromJson(
      locale,
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  /// Builds a translator over already-parsed tables, for tests and for
  /// callers that manage loading themselves.
  factory Translations.fromTables(
    TranslationTable active, [
    TranslationTable? fallback,
  ]) => Translations._(active, fallback);

  /// Translates [key], interpolating `{{name}}` placeholders from [args].
  String t(String key, {Map<String, Object?>? args}) {
    final template = _active[key] ?? _fallback?[key];
    if (template == null) return key;
    if (args == null || args.isEmpty) return template;

    return template.replaceAllMapped(RegExp(r'\{\{\s*(\w+)\s*\}\}'), (match) {
      final name = match[1]!;
      // Leave an unknown placeholder intact rather than blanking it, so a
      // missing argument is visible instead of silently swallowed.
      return args.containsKey(name) ? '${args[name]}' : match[0]!;
    });
  }
}
