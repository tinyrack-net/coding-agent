import 'package:coding_agent_app/core/forge.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defines every Paseo forge and its presentation contract', () {
    expect(forgePresentations.map((forge) => forge.id), [
      'github',
      'gitlab',
      'gitea',
      'forgejo',
      'codeberg',
    ]);
    expect(getForgePresentation('gitlab')!.changeRequestAbbrev, 'MR');
    expect(getForgePresentation('gitlab')!.changeRequestNoun, 'merge request');
    expect(getForgePresentation('gitlab')!.changeRequestNumberPrefix, '!');
    expect(getForgePresentation('github')!.cloudHosts, [
      'github.com',
      'ssh.github.com',
    ]);
  });

  test('uses exact brand colors and keeps GitHub neutral', () {
    expect(getForgeBrandColor('github'), isNull);
    expect(getForgeBrandColor('gitlab'), const Color(0xfffc6d26));
    expect(getForgeBrandColor('gitea'), const Color(0xff609926));
    expect(getForgeBrandColor('forgejo'), const Color(0xfffb923c));
    expect(getForgeBrandColor('codeberg'), const Color(0xff2185d0));
    expect(getForgeBrandColor('unknown'), isNull);
  });

  test('unknown forge resolves to a neutral, non-GitHub contract', () {
    final forge = getForgePresentationOrNeutral('bitbucket');
    expect(forge.displayName, 'bitbucket');
    expect(forge.iconKind, 'git');
    expect(forge.changeRequestNoun, 'pull request');
  });

  testWidgets('renders registered SVGs and a generic unknown fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const FluentApp(
        home: Row(
          children: [
            ForgeBrandIcon(iconKind: 'gitlab', size: 16, color: Colors.black),
            ForgeBrandIcon(iconKind: 'unknown', size: 16, color: Colors.black),
          ],
        ),
      ),
    );
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byIcon(FluentIcons.branch_fork2), findsOneWidget);
  });
}
