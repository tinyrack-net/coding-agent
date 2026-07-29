import 'package:coding_agent_app/core/forge.dart';
import 'package:coding_agent_app/core/forge_url.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defines every Paseo forge and its presentation contract', () {
    expect(forgeDefinitions.map((forge) => forge.id), [
      'github',
      'gitlab',
      'gitea',
      'forgejo',
      'codeberg',
    ]);
    expect(getForgeDefinition('gitlab')!.changeRequestAbbrev, 'MR');
    expect(getForgeDefinition('gitlab')!.changeRequestNoun, 'merge request');
    expect(getForgeDefinition('gitlab')!.changeRequestNumberPrefix, '!');
    expect(getForgeDefinition('github')!.cloudHosts, [
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
    final forge = getForgeDefinitionOrNeutral('bitbucket');
    expect(forge.displayName, 'bitbucket');
    expect(forge.iconKind, 'git');
    expect(forge.changeRequestNoun, 'pull request');
  });

  group('normalizeForge and auth parsing', () {
    test('defaults only absent or empty ids and preserves unknown ids', () {
      expect(normalizeForge('gitlab'), 'gitlab');
      expect(normalizeForge('bitbucket'), 'bitbucket');
      expect(normalizeForge(null), 'github');
      expect(normalizeForge(''), 'github');
    });

    test('accepts exactly the five wire auth states', () {
      for (final state in ForgeAuthState.values) {
        expect(parseForgeAuthState(state.wireName), state);
      }
      expect(parseForgeAuthState('missing'), isNull);
      expect(parseForgeAuthState(null), isNull);
      expect(parseForgeAuthState(1), isNull);
    });
  });

  group('getForgePresentation', () {
    test('maps pull-request and merge-request vocabularies', () {
      final github = getForgePresentation('github');
      expect(github.brandLabel, 'GitHub');
      expect(github.changeRequestAbbrev, 'PR');
      expect(github.numberPrefix, '#');
      expect(github.issueNumberPrefix, '#');
      expect(github.changeRequestContext, isNull);
      expect(github.signInCli, 'gh');

      final gitlab = getForgePresentation('gitlab');
      expect(gitlab.brandLabel, 'GitLab');
      expect(gitlab.changeRequestAbbrev, 'MR');
      expect(gitlab.changeRequestNoun, 'merge request');
      expect(gitlab.numberPrefix, '!');
      expect(gitlab.changeRequestContext, 'mr');
      expect(gitlab.signInCli, 'glab');
    });

    test('exposes URL builders only for known grammars', () {
      final github = getForgePresentation('github');
      expect(
        github.buildBranchTreeUrl!(
          const ForgeBranchTreeUrlInput(
            remoteUrl: 'git@github.com:acme/repo.git',
            branch: 'main',
          ),
        ),
        'https://github.com/acme/repo/tree/main',
      );
      expect(
        github.buildBlobUrl!(
          const ForgeBlobUrlInput(
            remoteUrl: 'git@github.com:acme/repo.git',
            branch: 'main',
            path: 'README.md',
          ),
        ),
        'https://github.com/acme/repo/blob/main/README.md',
      );
      final unknown = getForgePresentation('bitbucket');
      expect(unknown.brandLabel, 'bitbucket');
      expect(unknown.icon, 'git');
      expect(unknown.buildBranchTreeUrl, isNull);
      expect(unknown.buildBlobUrl, isNull);
    });

    test('presents the Gitea family with tea', () {
      for (final forge in ['gitea', 'forgejo', 'codeberg']) {
        final presentation = getForgePresentation(forge);
        expect(presentation.forge, forge);
        expect(presentation.icon, forge);
        expect(presentation.changeRequestAbbrev, 'PR');
        expect(presentation.signInCli, 'tea');
      }
    });
  });

  group('forgeFromRemoteUrl', () {
    test('detects only exact public cloud hosts', () {
      expect(
        forgeFromRemoteUrl('https://codeberg.org/example/repo.git'),
        'codeberg',
      );
      expect(
        forgeFromRemoteUrl('https://gitlab.com/example/repo.git'),
        'gitlab',
      );
      expect(forgeFromRemoteUrl('https://gitea.com/example/repo.git'), 'gitea');
      expect(
        forgeFromRemoteUrl('ssh://git@ssh.github.com/example/repo.git'),
        'github',
      );
    });

    test('does not infer a self-managed forge from substrings', () {
      for (final remote in [
        'git@gitlab.example.org:example/repo.git',
        'git@forgejo.example.org:example/repo.git',
        'https://notgitlab.example.org/example/repo.git',
        null,
      ]) {
        expect(forgeFromRemoteUrl(remote), isNull);
      }
    });
  });

  group('buildForgeSignInCommand', () {
    test('builds each manifest command and GitLab host targeting', () {
      expect(
        buildForgeSignInCommand('github', 'ssh.github.com'),
        'gh auth login',
      );
      expect(
        buildForgeSignInCommand('gitlab', 'gitlab.acme.com'),
        'glab auth login --hostname gitlab.acme.com',
      );
      for (final forge in ['gitea', 'forgejo', 'codeberg']) {
        expect(buildForgeSignInCommand(forge, 'example.org'), 'tea login add');
      }
    });

    test('handles missing host and unknown forge neutrally', () {
      expect(buildForgeSignInCommand('gitlab', null), 'glab auth login');
      expect(buildForgeSignInCommand('bitbucket', 'bitbucket.org'), isNull);
    });
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
