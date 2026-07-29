import 'package:agent_daemon/src/cli/cli_paths.dart';
import 'package:test/test.dart';

void main() {
  test('matches the same directory and separator-normalized descendants', () {
    expect(isSameOrDescendantPath('/repo', '/repo'), isTrue);
    expect(isSameOrDescendantPath('/repo/', '/repo/'), isTrue);
    expect(isSameOrDescendantPath('/repo', r'/repo\packages/app'), isTrue);
    expect(isSameOrDescendantPath(r'C:\repo', 'C:/repo/packages/app'), isTrue);
  });

  test('uses case-insensitive comparison when either path is Windows', () {
    expect(isSameOrDescendantPath(r'C:\Repo', r'c:\repo\APP'), isTrue);
    expect(isSameOrDescendantPath('/Repo', r'C:\REPO'), isFalse);
    expect(isSameOrDescendantPath('/Repo', '/repo/app'), isFalse);
  });

  test('requires a directory boundary rather than a shared prefix', () {
    expect(isSameOrDescendantPath('/repo', '/repository'), isFalse);
    expect(isSameOrDescendantPath(r'C:\repo', r'C:\repository'), isFalse);
    expect(isSameOrDescendantPath('/repo/app', '/repo'), isFalse);
  });

  test('preserves the frozen single trailing-separator normalization', () {
    expect(isSameOrDescendantPath('/', '/workspace'), isTrue);
    expect(isSameOrDescendantPath(r'C:\', r'C:\workspace'), isTrue);
    expect(isSameOrDescendantPath('/repo//', '/repo/app'), isFalse);
  });
}
