import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('classifies the exact supported complete remote transports', () {
    for (final remote in const [
      'https://github.com/owner/repo',
      'http://internal/owner/repo.git',
      'ssh://git@github.com/owner/repo',
      'git@github.com:owner/repo.git',
      '  https://github.com/owner/repo  ',
    ]) {
      expect(isCompleteGitRemote(remote), isTrue, reason: remote);
    }
    for (final shorthand in const [
      'owner/repo',
      'owner/repo.git',
      '',
      'git://github.com/owner/repo',
      'ftp://host/repo',
      'file:///tmp/repo',
    ]) {
      expect(isCompleteGitRemote(shorthand), isFalse, reason: shorthand);
      expect(parseGitRemoteLocation(shorthand), isNull, reason: shorthand);
    }
  });

  test('normalizes URL and scp locations', () {
    final url = parseGitRemoteLocation('ssh://git@GitHub.COM./owner/repo.git')!;
    expect(url.transport, 'ssh');
    expect(url.host, 'github.com');
    expect(url.path, 'owner/repo');

    final scp = parseGitRemoteLocation('git@github.com:owner/repo.git')!;
    expect(scp.transport, 'scp');
    expect(scp.host, 'github.com');
    expect(scp.path, 'owner/repo');
  });

  test('extracts only two-segment GitHub identities', () {
    final identity = parseGitHubRemoteUrl(
      'https://github.com/getpaseo/paseo.git',
    )!;
    expect(identity.owner, 'getpaseo');
    expect(identity.name, 'paseo');
    expect(identity.repo, 'getpaseo/paseo');
    expect(
      parseGitHubRemoteUrl('https://gitlab.com/getpaseo/paseo.git'),
      isNull,
    );
    expect(parseGitHubRemoteIdentity('group/subgroup/repo'), isNull);
    expect(isGitHubHost('GitHub.COM.'), isTrue);
  });

  test('treats ssh.github.com as GitHub, per the forge manifest', () {
    // GitHub hands out ssh.github.com for port-443 SSH access, and the frozen
    // forge manifest lists it alongside github.com in `cloudHosts`.
    for (final host in const [
      'github.com',
      'ssh.github.com',
      'SSH.GitHub.com',
      'ssh.github.com.',
    ]) {
      expect(isGitHubHost(host), isTrue, reason: host);
    }
    expect(isGitHubHost('gitlab.com'), isFalse);
    expect(isGitHubHost('notgithub.com'), isFalse);

    final parsed = parseGitHubRemoteUrl(
      'ssh://git@ssh.github.com/owner/repo.git',
    );
    expect(parsed?.repo, 'owner/repo');
  });

  test('rejects malformed hosts, paths, and escapes', () {
    for (final remote in const [
      'https://-invalid/repo',
      'https://host/',
      'https://host/%ZZ',
      'git@host:',
      'git@:owner/repo',
    ]) {
      expect(parseGitRemoteLocation(remote), isNull, reason: remote);
    }
  });
}
