/// Port of Paseo 0.2.0's `i18n/provider.tsx`.
///
/// Upstream wraps the tree in an `I18nextProvider` and calls
/// `ensureI18nLanguageForRender` on every render, because i18next is a
/// mutable singleton that has to be pushed at. Riverpod derives instead:
/// [translationsProvider] watches [resolvedLocaleProvider], so changing the
/// language reloads the table on its own and there is no imperative sync
/// step to forget. `ensureI18nLanguageForRender` is still ported in
/// `lib/i18n/sync_language.dart` for controller-shaped call sites.
library;

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n/locales.dart';
import '../i18n/translations.dart';

/// The OS locale list, most-preferred first, as BCP-47 tags.
///
/// Upstream reads `navigator.languages` on web and `expo-localization`
/// elsewhere; `PlatformDispatcher.locales` is the one Flutter equivalent of
/// both. Overridden in tests, which have no meaningful platform locale.
final systemLocalesProvider = Provider<List<String>>(
  (_) => PlatformDispatcher.instance.locales
      .map((locale) => locale.toLanguageTag())
      .toList(growable: false),
);

/// The persisted language setting, defaulting to following the OS.
class AppLanguageNotifier extends Notifier<AppLanguage> {
  static const _key = 'settings.language';

  @override
  AppLanguage build() {
    Future.microtask(_load);
    return AppLanguage.system;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(_key);
      // A value the app no longer ships (an old locale, a hand-edited
      // preference) parses to null and leaves the default in place rather
      // than rendering an empty UI.
      final parsed = parseAppLanguage(stored);
      if (parsed != null) state = parsed;
    } catch (_) {
      // Keep the session default when preferences are unavailable.
    }
  }

  Future<void> setLanguage(AppLanguage language) async {
    state = language;
    try {
      await (await SharedPreferences.getInstance()).setString(
        _key,
        language.code,
      );
    } catch (_) {
      // The in-memory selection still applies for this session.
    }
  }
}

final appLanguageProvider = NotifierProvider<AppLanguageNotifier, AppLanguage>(
  AppLanguageNotifier.new,
);

/// The concrete locale to render in: the explicit choice, or the first
/// supported OS locale, or English.
final resolvedLocaleProvider = Provider<SupportedLocale>(
  (ref) => resolveSupportedLocale(
    ref.watch(appLanguageProvider),
    ref.watch(systemLocalesProvider),
  ),
);

/// The active translator, reloaded whenever [resolvedLocaleProvider] changes.
final translationsProvider = FutureProvider<Translations>(
  (ref) => Translations.load(ref.watch(resolvedLocaleProvider)),
);
