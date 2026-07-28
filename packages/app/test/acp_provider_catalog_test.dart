import 'package:coding_agent_app/providers/acp_provider_catalog.dart';
import 'package:coding_agent_app/providers/acp_provider_catalog_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AcpProviderCatalogEntry find(String id) =>
      acpProviderCatalog.singleWhere((entry) => entry.id == id);

  test('vendors the complete frozen Paseo 0.2.0 ACP catalog', () {
    expect(acpProviderCatalog, hasLength(36));
    expect(
      acpProviderCatalog.map((entry) => entry.id).toSet(),
      hasLength(acpProviderCatalog.length),
    );
    for (final entry in acpProviderCatalog) {
      expect(entry.id, isNotEmpty, reason: entry.id);
      expect(entry.title, isNotEmpty, reason: entry.id);
      expect(entry.description, isNotEmpty, reason: entry.id);
      expect(entry.installLink, startsWith('https://'), reason: entry.id);
      expect(entry.command, isNotEmpty, reason: entry.id);
      expect(entry.command.first, isNotEmpty, reason: entry.id);
    }
    expect(
      acpProviderCatalog.where((entry) => entry.iconName != null),
      hasLength(33),
    );
    expect(
      acpProviderCatalog
          .where((entry) => entry.iconName != null)
          .every((entry) => entry.iconName == entry.id),
      isTrue,
    );
    expect(acpProviderCatalog.any((entry) => entry.id == 'pi-acp'), isFalse);
  });

  test('preserves PATH commands from binary distributions', () {
    expect(find('amp-acp').command, ['amp-acp']);
    expect(find('cursor').command, ['cursor-agent', 'acp']);
    expect(find('codewhale').command, ['codewhale', 'serve', '--acp']);
    expect(find('devin').command, ['devin', 'acp']);
    expect(find('goose').command, ['goose', 'acp']);
    expect(find('junie').command, ['junie', '--acp', 'true']);
    expect(find('kiro').command, ['kiro-cli', 'acp']);
    expect(find('poolside').command, ['pool', 'acp']);
    expect(find('traecli').command, ['traecli', 'acp', 'serve']);
  });

  test('builds the exact custom ACP daemon config patch', () {
    expect(buildAcpProviderConfigPatch(find('amp-acp')).toJson(), {
      'providers': {
        'amp-acp': {
          'extends': 'acp',
          'label': 'Amp',
          'description': 'ACP wrapper for Amp - the frontier coding agent',
          'command': ['amp-acp'],
          'env': <String, Object?>{},
        },
      },
    });
    expect(
      (buildAcpProviderConfigPatch(
            find('auggie'),
          ).providers!['auggie']!.extra['env']
          as Map<String, Object?>)['AUGMENT_DISABLE_AUTO_UPDATE'],
      '1',
    );
    expect(
      (buildAcpProviderConfigPatch(
            find('factory-droid'),
          ).providers!['factory-droid']!.extra['params']
          as Map<String, Object?>)['supportsMcpServers'],
      isFalse,
    );
  });

  test('search matches title, id, description, and blank query', () {
    final amp = find('amp-acp');
    expect(acpProviderMatchesSearch(amp, ''), isTrue);
    expect(acpProviderMatchesSearch(amp, ' AMP '), isTrue);
    expect(acpProviderMatchesSearch(amp, 'amp-acp'), isTrue);
    expect(acpProviderMatchesSearch(amp, 'frontier coding'), isTrue);
    expect(acpProviderMatchesSearch(amp, 'missing'), isFalse);
  });
}
