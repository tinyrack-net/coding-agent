import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const defaultCodeFontSize = 12.0;
const minimumCodeFontSize = 9.0;
const maximumCodeFontSize = 22.0;
const maximumFontFamilyLength = 200;

final class CodeAppearanceSettings {
  const CodeAppearanceSettings({
    this.monoFontFamily = '',
    this.codeFontSize = defaultCodeFontSize,
  });

  final String monoFontFamily;
  final double codeFontSize;

  CodeAppearanceSettings copyWith({
    String? monoFontFamily,
    double? codeFontSize,
  }) => CodeAppearanceSettings(
    monoFontFamily: monoFontFamily ?? this.monoFontFamily,
    codeFontSize: codeFontSize ?? this.codeFontSize,
  );
}

class CodeAppearanceNotifier extends Notifier<CodeAppearanceSettings> {
  static const _monoFontFamilyKey = 'appearance.monoFontFamily';
  static const _codeFontSizeKey = 'appearance.codeFontSize';

  @override
  CodeAppearanceSettings build() {
    Future.microtask(_load);
    return const CodeAppearanceSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = CodeAppearanceSettings(
        monoFontFamily: sanitizeMonoFontFamily(
          prefs.getString(_monoFontFamilyKey),
        ),
        codeFontSize: clampCodeFontSize(switch (prefs.get(_codeFontSizeKey)) {
          final num value => value,
          _ => null,
        }),
      );
    } catch (_) {
      // Keep the session defaults when preferences are unavailable.
    }
  }

  Future<void> setMonoFontFamily(String value) async {
    final sanitized = sanitizeMonoFontFamily(value);
    state = state.copyWith(monoFontFamily: sanitized);
    try {
      await (await SharedPreferences.getInstance()).setString(
        _monoFontFamilyKey,
        sanitized,
      );
    } catch (_) {}
  }

  Future<void> setCodeFontSize(num value) async {
    final clamped = clampCodeFontSize(value);
    state = state.copyWith(codeFontSize: clamped);
    try {
      await (await SharedPreferences.getInstance()).setDouble(
        _codeFontSizeKey,
        clamped,
      );
    } catch (_) {}
  }

  Future<void> reset() async {
    state = const CodeAppearanceSettings();
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.remove(_monoFontFamilyKey),
        prefs.remove(_codeFontSizeKey),
      ]);
    } catch (_) {}
  }
}

String sanitizeMonoFontFamily(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.length > maximumFontFamilyLength ||
      RegExp(r'[;{}<>]').hasMatch(trimmed) ||
      trimmed.codeUnits.any((unit) => unit <= 0x1f)) {
    return '';
  }
  return trimmed;
}

double clampCodeFontSize(num? value) {
  final candidate = value?.toDouble();
  if (candidate == null || !candidate.isFinite) return defaultCodeFontSize;
  return candidate.floorToDouble().clamp(
    minimumCodeFontSize,
    maximumCodeFontSize,
  );
}

final codeAppearanceProvider =
    NotifierProvider<CodeAppearanceNotifier, CodeAppearanceSettings>(
      CodeAppearanceNotifier.new,
    );
