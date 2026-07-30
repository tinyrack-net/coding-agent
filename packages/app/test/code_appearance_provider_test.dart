import 'package:coding_agent_app/state/code_appearance_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('code appearance loads, clamps, sanitizes, and persists', () async {
    SharedPreferences.setMockInitialValues({
      'appearance.monoFontFamily': '  JetBrains Mono  ',
      'appearance.codeFontSize': 999.0,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(codeAppearanceProvider);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(codeAppearanceProvider),
      isA<CodeAppearanceSettings>()
          .having(
            (value) => value.monoFontFamily,
            'mono font',
            'JetBrains Mono',
          )
          .having((value) => value.codeFontSize, 'code size', 22),
    );

    final notifier = container.read(codeAppearanceProvider.notifier);
    await notifier.setCodeFontSize(8);
    await notifier.setMonoFontFamily('  Cascadia Code  ');
    expect(container.read(codeAppearanceProvider).codeFontSize, 9);
    expect(
      container.read(codeAppearanceProvider).monoFontFamily,
      'Cascadia Code',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('appearance.codeFontSize'), 9);
    expect(prefs.getString('appearance.monoFontFamily'), 'Cascadia Code');

    await notifier.reset();
    expect(
      container.read(codeAppearanceProvider),
      isA<CodeAppearanceSettings>()
          .having((value) => value.monoFontFamily, 'mono font', '')
          .having((value) => value.codeFontSize, 'code size', 12),
    );
    expect(prefs.containsKey('appearance.codeFontSize'), isFalse);
    expect(prefs.containsKey('appearance.monoFontFamily'), isFalse);
  });

  test('invalid values use the frozen Paseo defaults', () {
    expect(clampCodeFontSize(null), defaultCodeFontSize);
    expect(clampCodeFontSize(double.nan), defaultCodeFontSize);
    expect(clampCodeFontSize(12.9), 12);
    expect(
      sanitizeMonoFontFamily(
        List.filled(maximumFontFamilyLength + 20, 'x').join(),
      ),
      '',
    );
    expect(sanitizeMonoFontFamily('bad;font'), '');
    expect(sanitizeMonoFontFamily('bad\nfont'), '');
  });
}
