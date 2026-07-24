import 'package:agent_daemon/src/providers/exe_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('ExeResolver.resolve', () {
    test('resolves a command that exists on PATH (git)', () async {
      final resolver = ExeResolver();
      final path = await resolver.resolve('git');
      expect(path, isNotNull);
      expect(path, isNotEmpty);
    });

    test('returns null for a command that does not exist', () async {
      final resolver = ExeResolver();
      final path =
          await resolver.resolve('definitely-not-a-real-command-xyz-123');
      expect(path, isNull);
    });

    test('caches the result across calls (second call is a cache hit)',
        () async {
      final resolver = ExeResolver();
      final first = await resolver.resolve('git');
      final second = await resolver.resolve('git');
      expect(second, first);
    });

    test('caches negative results too', () async {
      final resolver = ExeResolver();
      final first = await resolver.resolve('nope-nope-nope');
      final second = await resolver.resolve('nope-nope-nope');
      expect(first, isNull);
      expect(second, isNull);
    });

    test('falls back to the first match when no .exe candidate exists '
        '(e.g. the "flutter" launcher, which the Flutter SDK ships only as '
        'a shell script and a .bat shim on Windows, never a .exe)',
        () async {
      final resolver = ExeResolver();
      final path = await resolver.resolve('flutter');
      expect(path, isNotNull);
      // Neither candidate for `flutter` ends in `.exe` on any Flutter SDK
      // install (unlike `dart`, which does ship a real dart.exe and would
      // make this assertion environment-dependent), so the resolver must
      // exercise its "no .exe match" fallback (orElse: lines.first).
      expect(path!.toLowerCase(), isNot(endsWith('.exe')));
    });
  });

  group('ExeResolver.isBatchShim', () {
    test('true for .cmd and .bat, case-insensitively', () {
      expect(ExeResolver.isBatchShim(r'C:\tools\claude.cmd'), isTrue);
      expect(ExeResolver.isBatchShim(r'C:\tools\claude.CMD'), isTrue);
      expect(ExeResolver.isBatchShim(r'C:\tools\claude.bat'), isTrue);
      expect(ExeResolver.isBatchShim(r'C:\tools\claude.BAT'), isTrue);
    });

    test('false for .exe or extensionless paths', () {
      expect(ExeResolver.isBatchShim(r'C:\tools\claude.exe'), isFalse);
      expect(ExeResolver.isBatchShim('/usr/bin/claude'), isFalse);
    });
  });
}
