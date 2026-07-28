import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  late RelayKeyPair daemonKeyPair;
  late RelayKeyPair clientKeyPair;
  late Uint8List sharedKey;
  late List<Object> sent;
  late List<(int, String)> closes;
  late List<Object> received;
  late List<Object> errors;
  late RelayE2eeDaemonChannel channel;

  setUp(() {
    daemonKeyPair = RelayKeyPair.fromSecretKey(
      Uint8List.fromList(List<int>.generate(32, (index) => index + 1)),
    );
    clientKeyPair = RelayKeyPair.fromSecretKey(
      Uint8List.fromList(List<int>.generate(32, (index) => index + 33)),
    );
    sharedKey = deriveRelaySharedKey(
      secretKey: clientKeyPair.secretKey,
      peerPublicKey: daemonKeyPair.publicKey,
    );
    sent = [];
    closes = [];
    received = [];
    errors = [];
    channel = RelayE2eeDaemonChannel(
      daemonKeyPair: daemonKeyPair,
      transportSend: sent.add,
      transportClose: (code, reason) => closes.add((code, reason)),
      onMessage: received.add,
      onError: errors.add,
    );
  });

  String hello(RelayKeyPair keyPair) => jsonEncode({
    'type': 'e2ee_hello',
    'key': exportRelayPublicKey(keyPair.publicKey),
  });

  test('opens on valid hello and exchanges encrypted text and bytes', () async {
    channel.handleFrame(hello(clientKeyPair));

    await channel.ready;
    expect(channel.state, RelayE2eeChannelState.open);
    expect(sent, ['{"type":"e2ee_ready"}']);

    channel.handleFrame(
      base64.encode(encryptRelayPayload(sharedKey, '{"type":"ping"}')),
    );
    channel.handleFrame(
      utf8
          .encode(base64.encode(encryptRelayPayload(sharedKey, 'byte-text')))
          .toList(),
    );
    expect(received, ['{"type":"ping"}', 'byte-text']);

    channel.send(Uint8List.fromList([0xff, 0x00, 0x01]));
    final decrypted = decryptRelayPayload(
      sharedKey,
      base64.decode(sent.last as String),
    );
    expect(decrypted, isA<Uint8List>());
    expect(decrypted, orderedEquals([0xff, 0x00, 0x01]));
  });

  test('same client hello after open resends ready without rekeying', () async {
    channel.handleFrame(Uint8List.fromList(utf8.encode(hello(clientKeyPair))));
    await channel.ready;
    channel.handleFrame(utf8.encode(hello(clientKeyPair)).toList());

    expect(sent, ['{"type":"e2ee_ready"}', '{"type":"e2ee_ready"}']);
    expect(closes, isEmpty);
  });

  test('different client hello after open closes with policy violation', () {
    channel.handleFrame(hello(clientKeyPair));
    channel.handleFrame(hello(RelayKeyPair.generate()));

    expect(channel.state, RelayE2eeChannelState.closed);
    expect(closes, [
      (
        relayRehandshakeKeyMismatchCloseCode,
        relayRehandshakeKeyMismatchCloseReason,
      ),
    ]);
  });

  test('invalid initial hello fails the handshake', () async {
    channel.handleFrame('{"type":"hello"}');

    await expectLater(channel.ready, throwsA(isA<FormatException>()));
    expect(channel.state, RelayE2eeChannelState.closed);
    expect(closes.single.$1, 1011);
    expect(errors.single, isA<FormatException>());
  });

  test('plaintext application traffic after open is fatal', () async {
    channel.handleFrame(hello(clientKeyPair));
    await channel.ready;
    channel.handleFrame('{"type":"session"}');

    expect(channel.state, RelayE2eeChannelState.closed);
    expect(closes.last.$1, 1011);
    expect(errors.single, isA<StateError>());
  });

  test('close and transport close complete an unfinished handshake', () async {
    channel.close(1000, 'done');
    await expectLater(channel.ready, throwsA(isA<StateError>()));
    expect(closes, [(1000, 'done')]);

    final second = RelayE2eeDaemonChannel(
      daemonKeyPair: daemonKeyPair,
      transportSend: (_) {},
      transportClose: (_, _) {},
      onMessage: (_) {},
    );
    second.transportClosed(1006, 'lost');
    await expectLater(second.ready, throwsA(isA<StateError>()));
  });

  test('send before handshake is rejected', () {
    expect(() => channel.send('early'), throwsStateError);
  });
}
