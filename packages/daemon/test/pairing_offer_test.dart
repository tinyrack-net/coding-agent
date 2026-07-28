import 'dart:io';

import 'package:agent_daemon/src/server/pairing_offer.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('pairing-offer-');
  });

  tearDown(() {
    home.deleteSync(recursive: true);
  });

  test('disabled relay returns no URL and creates no identity files', () async {
    final result = await generateLocalPairingOffer(
      tinyrackHome: home.path,
      relayEnabled: false,
    );

    expect(result.relayEnabled, isFalse);
    expect(result.url, isNull);
    expect(result.qr, isNull);
    expect(File(p.join(home.path, 'server-id')).existsSync(), isFalse);
  });

  test('builds a stable public relay offer URL', () async {
    final first = await generateLocalPairingOffer(
      tinyrackHome: home.path,
      relayEndpoint: 'relay.internal:8787',
      relayPublicEndpoint: 'hub.example.test:443',
      relayUseTls: false,
      relayPublicUseTls: true,
      appBaseUrl: 'https://app.example.test/',
      includeQr: false,
      environment: const {'TINYRACK_SERVER_ID': 'srv_test'},
    );
    final second = await generateLocalPairingOffer(
      tinyrackHome: home.path,
      relayEndpoint: 'relay.internal:8787',
      relayPublicEndpoint: 'hub.example.test:443',
      relayUseTls: false,
      relayPublicUseTls: true,
      appBaseUrl: 'https://app.example.test',
      includeQr: false,
      environment: const {},
    );

    expect(first.relayEnabled, isTrue);
    expect(first.url, second.url);
    final offer = parseConnectionOfferFromUrl(first.url!);
    expect(offer?.serverId, 'srv_test');
    expect(offer?.relay.endpoint, 'hub.example.test:443');
    expect(offer?.relay.useTls, isTrue);
    expect(offer?.daemonPublicKeyB64, isNotEmpty);
  });

  test('renders QR when requested and tolerates renderer failure', () async {
    final defaultRendered = await generateLocalPairingOffer(
      tinyrackHome: home.path,
    );
    expect(defaultRendered.qr, contains('\u001b[47m\u001b[30m'));

    final rendered = await generateLocalPairingOffer(
      tinyrackHome: home.path,
      renderQr: (url) async => 'QR:$url',
    );
    expect(rendered.qr, 'QR:${rendered.url}');

    final warnings = <String>[];
    final failed = await generateLocalPairingOffer(
      tinyrackHome: home.path,
      renderQr: (_) async => throw StateError('renderer unavailable'),
      log: warnings.add,
    );
    expect(failed.qr, isNull);
    expect(warnings.single, contains('failed to render pairing QR'));
  });
}
