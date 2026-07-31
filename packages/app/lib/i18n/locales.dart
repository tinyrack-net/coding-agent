/// Port of Paseo 0.2.0's `i18n/locales.ts`.
///
/// The supported locale set, the language picker's options and labels, and
/// the rule that turns the user's choice (or their OS locale list) into one
/// concrete locale.
library;

/// A locale the app ships translations for.
enum SupportedLocale {
  ar('ar'),
  en('en'),
  es('es'),
  fr('fr'),
  ja('ja'),
  ptBR('pt-BR'),
  ru('ru'),
  zhCN('zh-CN');

  const SupportedLocale(this.code);

  /// The frozen wire/BCP-47 code, which is not always the enum name.
  final String code;

  static SupportedLocale? fromCode(String code) {
    for (final locale in values) {
      if (locale.code == code) return locale;
    }
    return null;
  }
}

/// The user's language setting: an explicit locale, or follow the OS.
final class AppLanguage {
  const AppLanguage._(this.code, this.locale);

  /// Follow the operating system's locale list.
  static const system = AppLanguage._('system', null);

  final String code;

  /// Null for [system]; otherwise the chosen locale.
  final SupportedLocale? locale;

  factory AppLanguage.of(SupportedLocale locale) =>
      AppLanguage._(locale.code, locale);

  bool get isSystem => locale == null;

  @override
  bool operator ==(Object other) =>
      other is AppLanguage && other.code == code && other.locale == locale;

  @override
  int get hashCode => Object.hash(code, locale);

  @override
  String toString() => 'AppLanguage($code)';
}

final class LanguageOption {
  const LanguageOption({required this.value, required this.labelKey});

  final AppLanguage value;
  final String labelKey;
}

const defaultLocale = SupportedLocale.en;

/// The language picker's options, in frozen order.
final languageOptions = <LanguageOption>[
  const LanguageOption(
    value: AppLanguage.system,
    labelKey: 'settings.general.language.options.system',
  ),
  LanguageOption(
    value: AppLanguage.of(SupportedLocale.ar),
    labelKey: 'settings.general.language.options.ar',
  ),
  LanguageOption(
    value: AppLanguage.of(SupportedLocale.en),
    labelKey: 'settings.general.language.options.en',
  ),
  LanguageOption(
    value: AppLanguage.of(SupportedLocale.es),
    labelKey: 'settings.general.language.options.es',
  ),
  LanguageOption(
    value: AppLanguage.of(SupportedLocale.fr),
    labelKey: 'settings.general.language.options.fr',
  ),
  LanguageOption(
    value: AppLanguage.of(SupportedLocale.ja),
    labelKey: 'settings.general.language.options.ja',
  ),
  LanguageOption(
    value: AppLanguage.of(SupportedLocale.ptBR),
    labelKey: 'settings.general.language.options.ptBR',
  ),
  LanguageOption(
    value: AppLanguage.of(SupportedLocale.ru),
    labelKey: 'settings.general.language.options.ru',
  ),
  LanguageOption(
    value: AppLanguage.of(SupportedLocale.zhCN),
    labelKey: 'settings.general.language.options.zhCN',
  ),
];

/// Each language's name in its own language.
const languageNativeNames = <SupportedLocale, String>{
  SupportedLocale.ar: 'العربية',
  SupportedLocale.en: 'English',
  SupportedLocale.es: 'Español',
  SupportedLocale.fr: 'Français',
  SupportedLocale.ja: '日本語',
  SupportedLocale.ptBR: 'Português brasileiro',
  SupportedLocale.ru: 'Русский',
  SupportedLocale.zhCN: '简体中文',
};

/// Each language's name as written in every other language, so the picker
/// can show both the native name and the name in the active UI language.
const languageNamesByLocale = <SupportedLocale, Map<SupportedLocale, String>>{
  SupportedLocale.ar: {
    SupportedLocale.ar: 'العربية',
    SupportedLocale.en: 'الإنجليزية',
    SupportedLocale.es: 'الإسبانية',
    SupportedLocale.fr: 'الفرنسية',
    SupportedLocale.ja: 'اليابانية',
    SupportedLocale.ptBR: 'البرتغالية البرازيلية',
    SupportedLocale.ru: 'الروسية',
    SupportedLocale.zhCN: 'الصينية المبسطة',
  },
  SupportedLocale.en: {
    SupportedLocale.ar: 'Arabic',
    SupportedLocale.en: 'English',
    SupportedLocale.es: 'Spanish',
    SupportedLocale.fr: 'French',
    SupportedLocale.ja: 'Japanese',
    SupportedLocale.ptBR: 'Brazilian Portuguese',
    SupportedLocale.ru: 'Russian',
    SupportedLocale.zhCN: 'Simplified Chinese',
  },
  SupportedLocale.es: {
    SupportedLocale.ar: 'árabe',
    SupportedLocale.en: 'inglés',
    SupportedLocale.es: 'español',
    SupportedLocale.fr: 'francés',
    SupportedLocale.ja: 'japonés',
    SupportedLocale.ptBR: 'portugués brasileño',
    SupportedLocale.ru: 'ruso',
    SupportedLocale.zhCN: 'chino simplificado',
  },
  SupportedLocale.fr: {
    SupportedLocale.ar: 'arabe',
    SupportedLocale.en: 'anglais',
    SupportedLocale.es: 'espagnol',
    SupportedLocale.fr: 'français',
    SupportedLocale.ja: 'japonais',
    SupportedLocale.ptBR: 'portugais brésilien',
    SupportedLocale.ru: 'russe',
    SupportedLocale.zhCN: 'chinois simplifié',
  },
  SupportedLocale.ja: {
    SupportedLocale.ar: 'アラビア語',
    SupportedLocale.en: '英語',
    SupportedLocale.es: 'スペイン語',
    SupportedLocale.fr: 'フランス語',
    SupportedLocale.ja: '日本語',
    SupportedLocale.ptBR: 'ブラジルポルトガル語',
    SupportedLocale.ru: 'ロシア語',
    SupportedLocale.zhCN: '簡体字中国語',
  },
  SupportedLocale.ptBR: {
    SupportedLocale.ar: 'árabe',
    SupportedLocale.en: 'inglês',
    SupportedLocale.es: 'espanhol',
    SupportedLocale.fr: 'francês',
    SupportedLocale.ja: 'japonês',
    SupportedLocale.ptBR: 'Português brasileiro',
    SupportedLocale.ru: 'russo',
    SupportedLocale.zhCN: 'chinês simplificado',
  },
  SupportedLocale.ru: {
    SupportedLocale.ar: 'арабский',
    SupportedLocale.en: 'английский',
    SupportedLocale.es: 'испанский',
    SupportedLocale.fr: 'французский',
    SupportedLocale.ja: 'японский',
    SupportedLocale.ptBR: 'бразильский португальский',
    SupportedLocale.ru: 'русский',
    SupportedLocale.zhCN: 'упрощенный китайский',
  },
  SupportedLocale.zhCN: {
    SupportedLocale.ar: '阿拉伯语',
    SupportedLocale.en: '英语',
    SupportedLocale.es: '西班牙语',
    SupportedLocale.fr: '法语',
    SupportedLocale.ja: '日语',
    SupportedLocale.ptBR: '巴西葡萄牙语',
    SupportedLocale.ru: '俄语',
    SupportedLocale.zhCN: '简体中文',
  },
};

/// Parses a persisted language setting, returning null for anything the app
/// does not ship.
AppLanguage? parseAppLanguage(Object? value) {
  if (value is! String) return null;
  if (value == 'system') return AppLanguage.system;
  final locale = SupportedLocale.fromCode(value);
  return locale == null ? null : AppLanguage.of(locale);
}

/// Labels a picker option: the system option uses the caller's translated
/// label, and a language shows its native name plus its name in the active
/// UI language — collapsed to one when those coincide.
String formatLanguageOptionLabel(
  LanguageOption option,
  SupportedLocale activeLocale,
  String systemLabel,
) {
  final locale = option.value.locale;
  if (locale == null) return systemLabel;

  final nativeName = languageNativeNames[locale]!;
  final activeLanguageName = languageNamesByLocale[activeLocale]![locale]!;
  if (nativeName == activeLanguageName) return nativeName;

  return '$nativeName - $activeLanguageName';
}

/// Resolves the concrete locale to render in. An explicit choice wins;
/// otherwise the OS locale list is scanned in order for the first supported
/// match, falling back to English.
///
/// Portuguese is deliberately narrow: only `pt` and `pt-BR` map to Brazilian
/// Portuguese, so European or African Portuguese falls back rather than
/// being shown the wrong variant.
SupportedLocale resolveSupportedLocale(
  AppLanguage language,
  List<String> systemLocales,
) {
  final explicit = language.locale;
  if (explicit != null) return explicit;

  for (final raw in systemLocales) {
    final normalized = raw.toLowerCase();
    if (normalized == 'ar' || normalized.startsWith('ar-')) {
      return SupportedLocale.ar;
    }
    if (normalized == 'en' || normalized.startsWith('en-')) {
      return SupportedLocale.en;
    }
    if (normalized == 'es' || normalized.startsWith('es-')) {
      return SupportedLocale.es;
    }
    if (normalized == 'fr' || normalized.startsWith('fr-')) {
      return SupportedLocale.fr;
    }
    if (normalized == 'ja' || normalized.startsWith('ja-')) {
      return SupportedLocale.ja;
    }
    if (normalized == 'pt' || normalized == 'pt-br') {
      return SupportedLocale.ptBR;
    }
    if (normalized == 'ru' || normalized.startsWith('ru-')) {
      return SupportedLocale.ru;
    }
    if (normalized == 'zh' ||
        normalized == 'zh-cn' ||
        normalized.startsWith('zh-hans')) {
      return SupportedLocale.zhCN;
    }
  }

  return defaultLocale;
}
