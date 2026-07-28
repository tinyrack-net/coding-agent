import 'package:agent_daemon/src/voice/provider_resolver.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/stt_manager.dart';
import 'package:test/test.dart';

void main() {
  test('wraps direct and nullable provider values', () {
    final direct = Object();

    expect(toResolver<Object>(direct)(), same(direct));
    expect(toResolver<Object?>(null)(), isNull);
  });

  test('preserves lazy resolver identity and reevaluates it', () {
    var value = 1;
    int resolve() => value;

    final normalized = toResolver<int>(resolve);
    expect(normalized, same(resolve));
    expect(normalized(), 1);
    value = 2;
    expect(normalized(), 2);
  });

  test('retains frozen function-as-resolver behavior', () {
    String Function() createProvider() =>
        () => 'provider';

    final normalized = toResolver<String Function()>(createProvider);
    expect(normalized()(), 'provider');
  });

  test('reports a mismatched direct boundary when resolved', () {
    final normalized = toResolver<int>('not-an-int');

    expect(normalized, throwsA(isA<TypeError>()));
  });

  test('speech managers accept a direct provider or a lazy resolver', () {
    final direct = _SttProvider('direct');
    final lazy = _SttProvider('lazy');

    expect(
      SttManager(
        sessionId: 'direct',
        logger: const NullSpeechLogger(),
        resolveStt: direct,
        environment: const {},
        cwd: '.',
      ).getProvider(),
      same(direct),
    );
    expect(
      SttManager(
        sessionId: 'lazy',
        logger: const NullSpeechLogger(),
        resolveStt: () => lazy,
        environment: const {},
        cwd: '.',
      ).getProvider(),
      same(lazy),
    );
  });
}

final class _SttProvider implements SpeechToTextProvider {
  const _SttProvider(this.id);

  @override
  final String id;

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) => throw UnimplementedError();
}
