/// Port of Paseo 0.2.0's `i18n/sync-language.ts` and `i18n/init.ts`.
///
/// Both keep localization failures non-fatal: a language switch or a failed
/// initialization is reported, never thrown, so the UI still renders (in
/// the previous or fallback language) rather than crashing.
library;

import 'dart:async';

import 'locales.dart';

/// Reports a localization failure. Defaults to stderr.
typedef I18nErrorReporter = void Function(String message, Object error);

/// What [ensureI18nLanguageForRender] drives.
abstract interface class I18nLanguageController {
  /// The currently active locale code, or null before initialization.
  String? get language;

  Future<void> changeLanguage(SupportedLocale locale);
}

void reportI18nError(String message, Object error) {
  // ignore: avoid_print
  print('$message: $error');
}

/// Switches the active language to [locale] if it is not already active.
///
/// Fire-and-forget by design: rendering must not block on the switch, and a
/// failure leaves the previous language in place rather than propagating.
void ensureI18nLanguageForRender(
  SupportedLocale locale,
  I18nLanguageController i18n, [
  I18nErrorReporter reportError = reportI18nError,
]) {
  if (i18n.language == locale.code) return;

  unawaited(
    i18n.changeLanguage(locale).catchError((Object error) {
      reportError('[i18n] Failed to change language', error);
    }),
  );
}

/// Observes initialization so a failure is reported rather than surfacing
/// as an unhandled error.
void observeI18nInit(
  Future<void> initFuture, [
  I18nErrorReporter report = reportI18nError,
]) {
  unawaited(
    initFuture.catchError((Object error) {
      report('[i18n] Failed to initialize', error);
    }),
  );
}
