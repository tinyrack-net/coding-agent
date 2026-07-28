import 'package:agent_daemon/src/server/hostnames.dart';
import 'package:test/test.dart';

void main() {
  test(
    'allows localhost, localhost subdomains, and IP addresses by default',
    () {
      expect(isHostnameAllowed('localhost:6767', null), isTrue);
      expect(isHostnameAllowed('foo.localhost:6767', null), isTrue);
      expect(isHostnameAllowed('127.0.0.1:6767', null), isTrue);
      expect(isHostnameAllowed('[::1]:6767', null), isTrue);
      expect(isHostnameAllowed('evil.com:6767', null), isFalse);
    },
  );

  test('allows any valid host when configured true', () {
    expect(isHostnameAllowed('evil.com:6767', true), isTrue);
    expect(isHostnameAllowed('', true), isFalse);
    expect(isHostnameAllowed('[broken', true), isFalse);
  });

  test('supports normalized exact and leading-dot patterns', () {
    const hostnames = ['.example.com', 'MYHOST'];
    expect(isHostnameAllowed('example.com:6767', hostnames), isTrue);
    expect(isHostnameAllowed('foo.example.com:6767', hostnames), isTrue);
    expect(isHostnameAllowed('foo.bar.example.com:6767', hostnames), isTrue);
    expect(isHostnameAllowed('notexample.com:6767', hostnames), isFalse);
    expect(isHostnameAllowed('myhost:6767', hostnames), isTrue);
  });

  test('merges arrays with trim and de-duplication, and true wins', () {
    expect(
      mergeHostnames([
        ['a', ' a '],
        ['b', ''],
        null,
      ]),
      ['a', 'b'],
    );
    expect(
      mergeHostnames([
        ['a'],
        true,
        ['b'],
      ]),
      isTrue,
    );
  });

  test('parses environment and persisted compatibility values', () {
    expect(parseHostnamesEnv(null), isNull);
    expect(parseHostnamesEnv(''), isNull);
    expect(parseHostnamesEnv(' TRUE '), isTrue);
    expect(parseHostnamesEnv('localhost, .example.com,,'), [
      'localhost',
      '.example.com',
    ]);
    expect(parsePersistedHostnames(null, 'daemon.hostnames'), isNull);
    expect(parsePersistedHostnames(true, 'daemon.hostnames'), isTrue);
    expect(parsePersistedHostnames(['.example.com'], 'daemon.hostnames'), [
      '.example.com',
    ]);
    expect(
      () => parsePersistedHostnames(false, 'daemon.hostnames'),
      throwsFormatException,
    );
    expect(
      () => parsePersistedHostnames([1], 'daemon.hostnames'),
      throwsFormatException,
    );
  });
}
