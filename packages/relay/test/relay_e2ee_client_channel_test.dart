import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  late RelayKeyPair daemon;
  late List<Object> sent;
  late List<(int, String)> closed;
  late List<Object> messages;
  late List<Object> errors;

  setUp(() {
    daemon = RelayKeyPair.fromSecretKey(
      Uint8List.fromList(List<int>.generate(32, (index) => index + 32)),
    );
    sent = [];
    closed = [];
    messages = [];
    errors = [];
  });

  RelayE2eeClientChannel channel({
    Duration retry = const Duration(hours: 1),
    int maxPendingSends = 200,
  }) => RelayE2eeClientChannel(
    daemonPublicKeyB64: exportRelayPublicKey(daemon.publicKey),
    transportSend: sent.add,
    transportClose: (code, reason) => closed.add((code, reason)),
    onMessage: messages.add,
    onError: errors.add,
    keyPair: RelayKeyPair.fromSecretKey(Uint8List(32)),
    handshakeRetry: retry,
    maxPendingSends: maxPendingSends,
  );

  test('sends hello, waits for ready, then flushes encrypted sends', () async {
    final client = channel();
    client.start();
    client.send('first');
    expect(jsonDecode(sent.single as String), {
      'type': 'e2ee_hello',
      'key': client.clientPublicKeyB64,
    });

    client.handleFrame(jsonEncode({'type': 'e2ee_ready'}));
    await client.ready;
    expect(client.state, RelayE2eeChannelState.open);
    expect(sent, hasLength(2));

    final shared = deriveRelaySharedKey(
      secretKey: daemon.secretKey,
      peerPublicKey: importRelayPublicKey(client.clientPublicKeyB64),
    );
    expect(
      decryptRelayPayload(shared, base64.decode(sent.last as String)),
      'first',
    );
    client.close();
  });

  test('decrypts inbound text and binary frames', () async {
    final client = channel();
    client.start();
    client.handleFrame('{"type":"e2ee_ready"}');
    await client.ready;
    final shared = deriveRelaySharedKey(
      secretKey: daemon.secretKey,
      peerPublicKey: importRelayPublicKey(client.clientPublicKeyB64),
    );
    client.handleFrame(base64.encode(encryptRelayPayload(shared, 'hello')));
    client.handleFrame(
      Uint8List.fromList(
        utf8.encode(
          base64.encode(
            encryptRelayPayload(shared, Uint8List.fromList([0xff, 0xfe])),
          ),
        ),
      ),
    );
    client.handleFrame(
      utf8
          .encode(base64.encode(encryptRelayPayload(shared, 'from-list')))
          .toList(),
    );
    expect(messages.first, 'hello');
    expect(messages[1], orderedEquals([0xff, 0xfe]));
    expect(messages.last, 'from-list');
    client.close();
  });

  test('generates an ephemeral client key when none is supplied', () async {
    final client = RelayE2eeClientChannel(
      daemonPublicKeyB64: exportRelayPublicKey(daemon.publicKey),
      transportSend: sent.add,
      transportClose: (code, reason) => closed.add((code, reason)),
      onMessage: messages.add,
    );
    client.start();
    client.handleFrame(utf8.encode('{"type":"e2ee_ready"}').toList());
    await client.ready;
    expect(importRelayPublicKey(client.clientPublicKeyB64), hasLength(32));
    client.handleFrame(utf8.encode('{"type":"hello"}').toList());
    expect(client.state, RelayE2eeChannelState.closed);
  });

  test('retries hello and caps pending sends at the Paseo limit', () async {
    final client = channel(
      retry: const Duration(milliseconds: 5),
      maxPendingSends: 2,
    );
    client.start();
    client.send('dropped');
    client.send('kept-1');
    client.send('kept-2');
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(sent.length, greaterThan(1));
    client.handleFrame('{"type":"e2ee_ready"}');
    await client.ready;
    final encrypted = sent.skipWhile(
      (frame) => (frame as String).startsWith('{'),
    );
    expect(encrypted, hasLength(2));
    client.close();
  });

  test('ignores handshake noise and repeated ready messages', () async {
    final client = channel();
    client.start();
    client.handleFrame('not ready');
    expect(client.state, RelayE2eeChannelState.handshaking);
    client.handleFrame('{"type":"e2ee_ready"}');
    await client.ready;
    client.handleFrame('{"type":"e2ee_ready"}');
    expect(messages, isEmpty);
    client.close();
  });

  test('closes on plaintext app traffic and decryption failures', () async {
    for (final invalid in ['{"type":"hello"}', 'not-base64']) {
      sent.clear();
      closed.clear();
      final client = channel();
      client.start();
      client.handleFrame('{"type":"e2ee_ready"}');
      await client.ready;
      client.handleFrame(invalid);
      expect(client.state, RelayE2eeChannelState.closed);
      expect(closed.single.$1, 1011);
      expect(errors, isNotEmpty);
      errors.clear();
    }
  });

  test('reports send errors and handshake transport closure', () async {
    final client = RelayE2eeClientChannel(
      daemonPublicKeyB64: exportRelayPublicKey(daemon.publicKey),
      transportSend: (_) => throw StateError('closed'),
      transportClose: (code, reason) {},
      onMessage: (_) {},
      onError: errors.add,
      keyPair: RelayKeyPair.fromSecretKey(Uint8List(32)),
    );
    client.start();
    expect(errors.single, isA<StateError>());
    client.transportClosed(4000, 'gone');
    await expectLater(client.ready, throwsStateError);
    expect(client.state, RelayE2eeChannelState.closed);
  });

  test('close during handshake completes ready with an error', () async {
    final client = channel();
    client.start();
    client.close(4000, 'cancel');
    await expectLater(client.ready, throwsStateError);
    expect(closed.single, (4000, 'cancel'));
    expect(() => client.send('late'), throwsStateError);
    client.close();
  });
}
