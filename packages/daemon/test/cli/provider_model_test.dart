import 'package:agent_daemon/src/cli/provider_model.dart';
import 'package:test/test.dart';

void main() {
  test('resolves plain, default, and provider/model inputs', () {
    expect(
      resolveProviderAndModel(provider: ' codex '),
      isA<ResolvedProviderModel>()
          .having((value) => value.provider, 'provider', 'codex')
          .having((value) => value.model, 'model', isNull),
    );
    expect(
      resolveProviderAndModel(defaultProvider: 'claude', model: ' sonnet '),
      isA<ResolvedProviderModel>()
          .having((value) => value.provider, 'provider', 'claude')
          .having((value) => value.model, 'model', 'sonnet'),
    );
    expect(
      resolveProviderAndModel(provider: ' codex/gpt-5.4 '),
      isA<ResolvedProviderModel>()
          .having((value) => value.provider, 'provider', 'codex')
          .having((value) => value.model, 'model', 'gpt-5.4'),
    );
    expect(
      resolveProviderAndModel(
        provider: 'codex/gpt-5.4',
        model: 'gpt-5.4',
      ).model,
      'gpt-5.4',
    );
  });

  test('reports every frozen validation code and detail', () {
    ProviderModelFormatException capture(void Function() callback) {
      try {
        callback();
        fail('Expected ProviderModelFormatException');
      } on ProviderModelFormatException catch (error) {
        return error;
      }
    }

    final missing = capture(resolveProviderAndModel);
    expect(missing.code, 'MISSING_PROVIDER');
    expect(missing.message, 'Provider is required');
    expect(missing.details, contains('coding-agent provider ls'));

    final emptyModel = capture(
      () => resolveProviderAndModel(provider: 'codex', model: ' '),
    );
    expect(emptyModel.code, 'INVALID_MODEL');
    expect(emptyModel.message, '--model cannot be empty');

    for (final provider in ['codex/', '/gpt-5.4']) {
      final invalid = capture(
        () => resolveProviderAndModel(provider: provider),
      );
      expect(invalid.code, 'INVALID_PROVIDER');
      expect(invalid.details, contains('<provider>/<model>'));
    }

    final conflicting = capture(
      () =>
          resolveProviderAndModel(provider: 'codex/gpt-5.4', model: 'gpt-5.5'),
    );
    expect(conflicting.code, 'CONFLICTING_MODEL_OPTIONS');
    expect(conflicting.message, 'Conflicting model values provided');
    expect(conflicting.details, contains('gpt-5.4'));
    expect(conflicting.details, contains('gpt-5.5'));
  });
}
