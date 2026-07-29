import 'package:coding_agent_app/widgets/pull_request_tab.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats the frozen pull-request tab label', () {
    expect(formatPullRequestTabLabel(42), '42');
    expect(formatPullRequestTabLabel(42.0), '42');
    expect(formatPullRequestTabLabel(null), '—');
  });

  testWidgets('renders each forge glyph at the requested size and color', (
    tester,
  ) async {
    const color = Color(0xff123456);

    for (final forge in ['github', 'gitlab', 'gitea', 'forgejo', 'codeberg']) {
      await tester.pumpWidget(
        FluentApp(
          home: PullRequestTabIcon(forge: forge, size: 13, color: color),
        ),
      );

      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.width, 13);
      expect(svg.height, 13);
      expect(
        svg.colorFilter,
        const ColorFilter.mode(color, BlendMode.srcIn),
        reason: '$forge must use the tab foreground instead of its brand color',
      );
    }
  });

  testWidgets('uses the neutral fallback for an unknown forge', (tester) async {
    const color = Color(0xff654321);
    await tester.pumpWidget(
      const FluentApp(
        home: PullRequestTabIcon(forge: 'bitbucket', size: 13, color: color),
      ),
    );

    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, FluentIcons.branch_fork2);
    expect(icon.size, 13);
    expect(icon.color, color);
  });
}
