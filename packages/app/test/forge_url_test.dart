import 'package:coding_agent_app/core/forge_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildForgeBranchTreeUrl', () {
    test('matches GitHub, GitLab, and Gitea-family grammars', () {
      expect(
        buildForgeBranchTreeUrl(
          'github',
          const ForgeBranchTreeUrlInput(
            remoteUrl: 'git@github.com:acme/repo.git',
            branch: 'feature/workspace-button',
          ),
        ),
        'https://github.com/acme/repo/tree/feature/workspace-button',
      );
      expect(
        buildForgeBranchTreeUrl(
          'gitlab',
          const ForgeBranchTreeUrlInput(
            remoteUrl: 'https://gitlab.com/group/sub/repo.git',
            branch: 'main',
          ),
        ),
        'https://gitlab.com/group/sub/repo/-/tree/main',
      );
      for (final forge in ['gitea', 'codeberg']) {
        expect(
          buildForgeBranchTreeUrl(
            forge,
            ForgeBranchTreeUrlInput(
              remoteUrl: forge == 'gitea'
                  ? 'https://gitea.com/acme/repo.git'
                  : 'https://codeberg.org/acme/repo.git',
              branch: 'main',
            ),
          ),
          'https://${forge == 'gitea' ? 'gitea.com' : 'codeberg.org'}'
          '/acme/repo/src/branch/main',
        );
      }
    });

    test('encodes branch segments and rejects missing contracts', () {
      expect(
        buildForgeBranchTreeUrl(
          'github',
          const ForgeBranchTreeUrlInput(
            remoteUrl: 'https://github.com/acme/repo.git',
            branch: 'feature/ship #42',
          ),
        ),
        'https://github.com/acme/repo/tree/feature/ship%20%2342',
      );
      for (final input in [
        const ForgeBranchTreeUrlInput(
          remoteUrl: 'https://github.com/acme/repo.git',
          branch: 'HEAD',
        ),
        const ForgeBranchTreeUrlInput(remoteUrl: null, branch: 'main'),
      ]) {
        expect(buildForgeBranchTreeUrl('github', input), isNull);
      }
      expect(
        buildForgeBranchTreeUrl(
          'bitbucket',
          const ForgeBranchTreeUrlInput(
            remoteUrl: 'https://bitbucket.org/acme/repo.git',
            branch: 'main',
          ),
        ),
        isNull,
      );
    });
  });

  group('buildForgeBlobUrl', () {
    test('matches every line anchor grammar', () {
      expect(
        _blob('github', lineStart: 12),
        'https://github.com/acme/repo/blob/main/src/index.ts#L12',
      );
      expect(
        _blob('github', lineStart: 12, lineEnd: 20),
        'https://github.com/acme/repo/blob/main/src/index.ts#L12-L20',
      );
      expect(
        _blob(
          'gitlab',
          remote: 'https://gitlab.com/group/sub/repo.git',
          lineStart: 12,
          lineEnd: 20,
        ),
        'https://gitlab.com/group/sub/repo/-/blob/main/src/index.ts#L12-20',
      );
      expect(
        _blob(
          'forgejo',
          remote: 'https://codeberg.org/acme/repo.git',
          lineStart: 12,
          lineEnd: 20,
        ),
        'https://codeberg.org/acme/repo/src/branch/main/src/index.ts#L12-L20',
      );
    });

    test('preserves self-hosted hosts and canonicalizes cloud SSH aliases', () {
      expect(
        _blob('github', remote: 'git@github.acme.internal:team/repo.git'),
        'https://github.acme.internal/team/repo/blob/main/src/index.ts',
      );
      expect(
        _blob('github', remote: 'ssh://git@ssh.github.com/acme/repo.git'),
        'https://github.com/acme/repo/blob/main/src/index.ts',
      );
    });

    test('normalizes and encodes file paths without allowing root escape', () {
      expect(
        _blob('github', path: r'\src\a b\c#d.ts'),
        'https://github.com/acme/repo/blob/main/src/a%20b/c%23d.ts',
      );
      expect(
        _blob('github', path: './src/../index.ts'),
        'https://github.com/acme/repo/blob/main/index.ts',
      );
      expect(_blob('github', path: '../outside.ts'), isNull);
      expect(_blob('github', path: ''), isNull);
      expect(_blob('bitbucket'), isNull);
    });

    test('rejects invalid remotes and repo paths', () {
      for (final remote in [
        'owner/repo',
        'git://github.com/acme/repo',
        'git@bad host:acme/repo.git',
      ]) {
        expect(_blob('github', remote: remote), isNull, reason: remote);
      }
    });
  });

  test('advertises URL support only for registered grammars', () {
    for (final forge in ['github', 'gitlab', 'gitea', 'forgejo', 'codeberg']) {
      expect(hasForgeWebUrls(forge), isTrue);
    }
    expect(hasForgeWebUrls('bitbucket'), isFalse);
  });
}

String? _blob(
  String forge, {
  String remote = 'https://github.com/acme/repo.git',
  String path = 'src/index.ts',
  int? lineStart,
  int? lineEnd,
}) => buildForgeBlobUrl(
  forge,
  ForgeBlobUrlInput(
    remoteUrl: remote,
    branch: 'main',
    path: path,
    lineStart: lineStart,
    lineEnd: lineEnd,
  ),
);
