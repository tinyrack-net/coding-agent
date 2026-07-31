// Ports of Paseo's `i18n/locales.test.ts`, `i18n/sync-language.test.ts`,
// `i18n/init.test.ts`, and `i18n/resources.test.ts` (key parity).
import 'dart:convert';
import 'dart:io';

import 'package:coding_agent_app/i18n/locales.dart';
import 'package:coding_agent_app/i18n/sync_language.dart';
import 'package:coding_agent_app/i18n/translations.dart';
import 'package:flutter_test/flutter_test.dart';

LanguageOption optionFor(AppLanguage language) =>
    languageOptions.firstWhere((option) => option.value == language);

class FakeLanguageController implements I18nLanguageController {
  FakeLanguageController(this.language, {this.failWith});

  @override
  String? language;
  final Object? failWith;
  final changes = <SupportedLocale>[];

  @override
  Future<void> changeLanguage(SupportedLocale locale) async {
    changes.add(locale);
    final failure = failWith;
    if (failure != null) throw failure;
    language = locale.code;
  }
}

Map<String, Object?> loadLocaleJson(String code) {
  final file = File('assets/i18n/$code.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  group('parseAppLanguage', () {
    test('accepts system and all supported locales', () {
      expect(parseAppLanguage('system'), AppLanguage.system);
      for (final locale in SupportedLocale.values) {
        expect(parseAppLanguage(locale.code), AppLanguage.of(locale));
      }
    });

    test('returns null for unknown values', () {
      expect(parseAppLanguage('de'), isNull);
      expect(parseAppLanguage(null), isNull);
      expect(parseAppLanguage(42), isNull);
    });
  });

  test('offers system plus all supported languages in frozen order', () {
    expect(languageOptions.map((option) => option.value.code), [
      'system',
      'ar',
      'en',
      'es',
      'fr',
      'ja',
      'pt-BR',
      'ru',
      'zh-CN',
    ]);
  });

  group('formatLanguageOptionLabel', () {
    test('shows the native name and the active-language name', () {
      expect(
        formatLanguageOptionLabel(
          optionFor(AppLanguage.of(SupportedLocale.ja)),
          SupportedLocale.en,
          'System',
        ),
        '日本語 - Japanese',
      );
      expect(
        formatLanguageOptionLabel(
          optionFor(AppLanguage.of(SupportedLocale.ar)),
          SupportedLocale.zhCN,
          '系统',
        ),
        'العربية - 阿拉伯语',
      );
    });

    test('uses a single label when both names match', () {
      expect(
        formatLanguageOptionLabel(
          optionFor(AppLanguage.of(SupportedLocale.en)),
          SupportedLocale.en,
          'System',
        ),
        'English',
      );
      expect(
        formatLanguageOptionLabel(
          optionFor(AppLanguage.of(SupportedLocale.ja)),
          SupportedLocale.ja,
          'システム',
        ),
        '日本語',
      );
      expect(
        formatLanguageOptionLabel(
          optionFor(AppLanguage.of(SupportedLocale.ptBR)),
          SupportedLocale.ptBR,
          'Sistema',
        ),
        'Português brasileiro',
      );
    });

    test('uses the caller-supplied label for System', () {
      expect(
        formatLanguageOptionLabel(
          optionFor(AppLanguage.system),
          SupportedLocale.zhCN,
          '系统',
        ),
        '系统',
      );
    });
  });

  group('resolveSupportedLocale', () {
    test('respects explicit language choices', () {
      for (final locale in SupportedLocale.values) {
        expect(
          resolveSupportedLocale(AppLanguage.of(locale), const ['en-US']),
          locale,
        );
      }
    });

    test('maps supported system locales', () {
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['ar-EG']),
        SupportedLocale.ar,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['en-US']),
        SupportedLocale.en,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['es-MX']),
        SupportedLocale.es,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['fr-CA']),
        SupportedLocale.fr,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['ja-JP']),
        SupportedLocale.ja,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['pt-BR']),
        SupportedLocale.ptBR,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['pt']),
        SupportedLocale.ptBR,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['ru-RU']),
        SupportedLocale.ru,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['zh-Hans-CN']),
        SupportedLocale.zhCN,
      );
    });

    test('does not map non-Brazilian Portuguese to Brazilian Portuguese', () {
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['pt-PT']),
        SupportedLocale.en,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['pt-AO']),
        SupportedLocale.en,
      );
    });

    test('takes the first supported system locale in order', () {
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['en-US', 'es-GB']),
        SupportedLocale.en,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['de-DE', 'es-MX']),
        SupportedLocale.es,
      );
    });

    test('falls back to English with nothing supported', () {
      expect(
        resolveSupportedLocale(AppLanguage.system, const ['de-DE']),
        SupportedLocale.en,
      );
      expect(
        resolveSupportedLocale(AppLanguage.system, const []),
        SupportedLocale.en,
      );
    });
  });

  group('ensureI18nLanguageForRender', () {
    test('is inert when the language already matches', () {
      final controller = FakeLanguageController('ja');
      ensureI18nLanguageForRender(SupportedLocale.ja, controller);
      expect(controller.changes, isEmpty);
    });

    test('switches when the language differs', () async {
      final controller = FakeLanguageController('en');
      ensureI18nLanguageForRender(SupportedLocale.ja, controller);
      await Future<void>.delayed(Duration.zero);
      expect(controller.changes, [SupportedLocale.ja]);
    });

    test('reports a failed switch instead of throwing', () async {
      final controller = FakeLanguageController(
        'en',
        failWith: StateError('nope'),
      );
      final reported = <String>[];

      ensureI18nLanguageForRender(
        SupportedLocale.ja,
        controller,
        (message, error) => reported.add(message),
      );
      await Future<void>.delayed(Duration.zero);

      expect(reported, ['[i18n] Failed to change language']);
    });
  });

  group('observeI18nInit', () {
    test('reports a failed initialization instead of throwing', () async {
      final reported = <String>[];
      observeI18nInit(
        Future<void>.error(StateError('boom')),
        (message, error) => reported.add(message),
      );
      await Future<void>.delayed(Duration.zero);

      expect(reported, ['[i18n] Failed to initialize']);
    });

    test('is silent on success', () async {
      final reported = <String>[];
      observeI18nInit(
        Future<void>.value(),
        (message, _) => reported.add(message),
      );
      await Future<void>.delayed(Duration.zero);

      expect(reported, isEmpty);
    });
  });

  group('vendored translation resources', () {
    test('every locale carries the exact English key set', () {
      final en = TranslationTable.fromJson(
        SupportedLocale.en,
        loadLocaleJson('en'),
      );
      expect(en.length, 1509);

      for (final locale in SupportedLocale.values) {
        final table = TranslationTable.fromJson(
          locale,
          loadLocaleJson(locale.code),
        );
        expect(
          table.keys.toSet(),
          en.keys.toSet(),
          reason: '${locale.code} must match the English key set exactly',
        );
      }
    });

    test('resolves the keys the ported modules address', () {
      final en = Translations.fromTables(
        TranslationTable.fromJson(SupportedLocale.en, loadLocaleJson('en')),
      );

      for (final key in const [
        'composer.input.sendMessage',
        'composer.input.queueMessage',
        'composer.voice.dictation',
        'agentControls.thinking.extraHigh',
        'settings.general.language.options.system',
      ]) {
        expect(en.t(key), isNot(key), reason: '$key should resolve');
      }
    });
  });

  group('Translations.t', () {
    final active = TranslationTable(SupportedLocale.ja, const {
      'greeting': 'こんにちは {{name}}',
      'only.ja': 'のみ',
    });
    final fallback = TranslationTable(SupportedLocale.en, const {
      'greeting': 'Hello {{name}}',
      'only.en': 'english only',
    });

    test('interpolates named placeholders', () {
      expect(
        Translations.fromTables(
          active,
          fallback,
        ).t('greeting', args: const {'name': 'Ada'}),
        'こんにちは Ada',
      );
    });

    test('falls back to English for a key the locale lacks', () {
      expect(
        Translations.fromTables(active, fallback).t('only.en'),
        'english only',
      );
    });

    test('returns the key itself when nothing resolves', () {
      expect(
        Translations.fromTables(active, fallback).t('missing.everywhere'),
        'missing.everywhere',
      );
    });

    test('leaves an unsupplied placeholder visible', () {
      expect(
        Translations.fromTables(active, fallback).t('greeting'),
        'こんにちは {{name}}',
      );
      expect(
        Translations.fromTables(
          active,
          fallback,
        ).t('greeting', args: const {'other': 'x'}),
        'こんにちは {{name}}',
      );
    });
  });
}
