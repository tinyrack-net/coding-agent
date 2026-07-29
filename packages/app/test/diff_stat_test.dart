import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/diff/diff_stat.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatDiffCount matches Paseo compact-number boundaries', () {
    expect(
      {
        for (final value in [
          0,
          999,
          1000,
          1050,
          1499,
          99949,
          999499,
          999950,
          1250000,
          999950000,
          1000000000000,
        ])
          value: formatDiffCount(value),
      },
      {
        0: '0',
        999: '999',
        1000: '1k',
        1050: '1.1k',
        1499: '1.5k',
        99949: '99.9k',
        999499: '999.5k',
        999950: '1m',
        1250000: '1.3m',
        999950000: '1b',
        1000000000000: '1t',
      },
    );
  });

  testWidgets('renders frozen geometry and light diff colors', (tester) async {
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(AppThemeName.light),
        home: const Center(child: DiffStat(additions: 1250, deletions: 999950)),
      ),
    );

    expect(find.text('+1.3k'), findsOneWidget);
    expect(find.text('-1m'), findsOneWidget);
    expect(tester.getSize(find.byType(DiffStat)).height, 20);

    final additions = tester.widget<Text>(find.text('+1.3k'));
    final deletions = tester.widget<Text>(find.text('-1m'));
    expect(additions.style?.fontSize, 12);
    expect(additions.style?.fontWeight, FontWeight.w400);
    expect(additions.style?.color, const Color(0xFF15803D));
    expect(deletions.style?.color, const Color(0xFFB91C1C));
    expect(
      tester.getTopLeft(find.text('-1m')).dx -
          tester.getTopRight(find.text('+1.3k')).dx,
      4,
    );
  });

  testWidgets('uses frozen dark diff colors', (tester) async {
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: const Center(child: DiffStat(additions: 1, deletions: 2)),
      ),
    );

    expect(
      tester.widget<Text>(find.text('+1')).style?.color,
      const Color(0xFF4ADE80),
    );
    expect(
      tester.widget<Text>(find.text('-2')).style?.color,
      const Color(0xFFEF4444),
    );
  });
}
