// Port of Paseo's `i18n/provider.tsx` behaviour: the settings language plus
// the OS locale list resolve to one concrete locale, and the translator
// follows that locale.
import 'package:coding_agent_app/i18n/locales.dart';
import 'package:coding_agent_app/i18n/translations.dart';
import 'package:coding_agent_app/state/language_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Builds the container and eagerly reads the language notifier, because it
/// is that first read which schedules the preference load.
ProviderContainer containerWith(List<String> systemLocales) {
  final container = ProviderContainer(
    overrides: [systemLocalesProvider.overrideWithValue(systemLocales)],
  );
  addTearDown(container.dispose);
  container.read(appLanguageProvider);
  return container;
}

/// Settles the microtask the notifier uses to read preferences, so a test
/// sees the persisted value rather than the pre-load default.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('appLanguageProvider', () {
    test('defaults to following the system', () async {
      final container = containerWith(const ['en-US']);
      expect(container.read(appLanguageProvider), AppLanguage.system);
      await settle();
      expect(container.read(appLanguageProvider), AppLanguage.system);
    });

    test('restores a persisted language', () async {
      SharedPreferences.setMockInitialValues({'settings.language': 'zh-CN'});
      final container = containerWith(const ['en-US']);
      await settle();
      expect(
        container.read(appLanguageProvider),
        AppLanguage.of(SupportedLocale.zhCN),
      );
    });

    test('ignores a language the app no longer ships', () async {
      SharedPreferences.setMockInitialValues({'settings.language': 'klingon'});
      final container = containerWith(const ['en-US']);
      await settle();
      expect(container.read(appLanguageProvider), AppLanguage.system);
    });

    test('persists a selection', () async {
      final container = containerWith(const ['en-US']);
      await settle();

      await container
          .read(appLanguageProvider.notifier)
          .setLanguage(AppLanguage.of(SupportedLocale.ja));

      expect(
        container.read(appLanguageProvider),
        AppLanguage.of(SupportedLocale.ja),
      );
      expect(
        (await SharedPreferences.getInstance()).getString('settings.language'),
        'ja',
      );
    });
  });

  group('resolvedLocaleProvider', () {
    test('follows the OS list when the setting is System', () async {
      final container = containerWith(const ['de-DE', 'fr-CA']);
      await settle();
      expect(container.read(resolvedLocaleProvider), SupportedLocale.fr);
    });

    test('falls back to English with nothing supported', () async {
      final container = containerWith(const ['de-DE']);
      await settle();
      expect(container.read(resolvedLocaleProvider), SupportedLocale.en);
    });

    test('an explicit choice overrides the OS list', () async {
      final container = containerWith(const ['en-US']);
      await settle();

      await container
          .read(appLanguageProvider.notifier)
          .setLanguage(AppLanguage.of(SupportedLocale.ru));

      expect(container.read(resolvedLocaleProvider), SupportedLocale.ru);
    });
  });

  group('translationsProvider', () {
    test('loads the resolved locale and reloads when it changes', () async {
      final container = containerWith(const ['ja-JP']);
      await settle();

      final japanese = await container.read(translationsProvider.future);
      expect(japanese.locale, SupportedLocale.ja);
      expect(japanese.t('settings.general.language.label'), isNot('Language'));

      await container
          .read(appLanguageProvider.notifier)
          .setLanguage(AppLanguage.of(SupportedLocale.en));

      final english = await container.read(translationsProvider.future);
      expect(english.locale, SupportedLocale.en);
      expect(english.t('settings.general.language.label'), 'Language');
    });

    test('a non-English locale falls back to English per key', () async {
      final container = containerWith(const ['ru-RU']);
      await settle();

      final russian = await container.read(translationsProvider.future);
      expect(russian.locale, SupportedLocale.ru);
      // Present in every locale, so this resolves without falling back.
      expect(russian.t('settings.general.language.label'), isNot(''));
      // Absent everywhere, so the key itself comes back.
      expect(russian.t('nope.not.a.key'), 'nope.not.a.key');
    });
  });

  group('formatLanguageOptionLabel over the picker options', () {
    test('labels every option in the active locale', () {
      final labels = [
        for (final option in languageOptions)
          formatLanguageOptionLabel(option, SupportedLocale.en, 'System'),
      ];

      expect(labels, [
        'System',
        'العربية - Arabic',
        'English',
        'Español - Spanish',
        'Français - French',
        '日本語 - Japanese',
        'Português brasileiro - Brazilian Portuguese',
        'Русский - Russian',
        '简体中文 - Simplified Chinese',
      ]);
    });
  });

  test('Translations.load reads the bundled assets', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final translations = await Translations.load(SupportedLocale.ja);
    expect(translations.t('settings.general.language.options.system'), 'システム');
  });
}
