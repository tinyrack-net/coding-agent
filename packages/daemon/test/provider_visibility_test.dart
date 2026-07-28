import 'package:agent_daemon/src/server/provider_visibility.dart';
import 'package:test/test.dart';

void main() {
  test('matches the frozen arbitrary-provider version boundary', () {
    expect(clientSupportsAllProviders(null), isFalse);
    expect(clientSupportsAllProviders('0.1.44'), isFalse);
    expect(clientSupportsAllProviders('0.1.45'), isTrue);
    expect(clientSupportsAllProviders('0.1.45-beta.4'), isTrue);
    expect(clientSupportsAllProviders('0.2.0'), isTrue);
    expect(clientSupportsAllProviders('1.0'), isTrue);
    expect(clientSupportsAllProviders('0.1.invalid'), isTrue);
    expect(clientSupportsAllProviders('0.x.45'), isTrue);
    expect(clientSupportsAllProviders('0.x.99'), isTrue);
    expect(clientSupportsAllProviders('0.1e0.45'), isTrue);
    expect(clientSupportsAllProviders('0..45'), isFalse);
  });

  test('legacy clients see only the frozen provider allowlist', () {
    for (final provider in ['claude', 'codex', 'opencode']) {
      expect(isProviderVisibleToClient(provider, '0.1.44'), isTrue);
    }
    expect(isProviderVisibleToClient('test', '0.1.44'), isFalse);
    expect(isProviderVisibleToClient('test', '0.1.45'), isTrue);
  });
}
