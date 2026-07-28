import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'relay_crypto.dart';
import 'relay_e2ee_client_channel.dart';

const relayRehandshakeKeyMismatchCloseCode = 1008;
const relayRehandshakeKeyMismatchCloseReason = 'E2EE re-handshake key mismatch';

/// Paseo-compatible responder-side encrypted relay channel.
///
/// The daemon owns a long-lived key pair whose public key is carried by the
/// pairing link. Each transport waits for the client's plaintext hello, sends
/// plaintext ready, and encrypts every subsequent application frame.
final class RelayE2eeDaemonChannel {
  RelayE2eeDaemonChannel({
    required RelayKeyPair daemonKeyPair,
    required RelayTransportSend transportSend,
    required RelayTransportClose transportClose,
    required RelayMessageHandler onMessage,
    void Function(Object error)? onError,
  }) : _daemonKeyPair = daemonKeyPair,
       _transportSend = transportSend,
       _transportClose = transportClose,
       _onMessage = onMessage,
       _onError = onError;

  final RelayKeyPair _daemonKeyPair;
  final RelayTransportSend _transportSend;
  final RelayTransportClose _transportClose;
  final RelayMessageHandler _onMessage;
  final void Function(Object error)? _onError;
  final _ready = Completer<void>();

  RelayE2eeChannelState _state = RelayE2eeChannelState.handshaking;
  Uint8List? _sharedKey;

  Future<void> get ready => _ready.future;
  RelayE2eeChannelState get state => _state;

  void handleFrame(Object data) {
    if (_state == RelayE2eeChannelState.closed) return;
    if (_state == RelayE2eeChannelState.handshaking) {
      _handleInitialHello(data);
      return;
    }
    final hello = _parseHello(data);
    if (hello != null) {
      _handleRehello(hello);
      return;
    }
    if (_isReadyMessage(data)) return;
    if (_looksLikePlaintextJson(data)) {
      _fail(StateError('Received plaintext frame on encrypted channel'));
      return;
    }
    try {
      final encoded = switch (data) {
        String() => data,
        Uint8List() => utf8.decode(data, allowMalformed: false),
        List<int>() => utf8.decode(data, allowMalformed: false),
        _ => throw const FormatException('Unsupported relay frame'),
      };
      final bundle = base64.decode(encoded);
      _onMessage(decryptRelayPayload(_sharedKey!, bundle));
    } on Object catch (error) {
      _fail(error);
    }
  }

  void send(Object data) {
    if (_state != RelayE2eeChannelState.open) {
      throw StateError('Channel not open');
    }
    _transportSend(base64.encode(encryptRelayPayload(_sharedKey!, data)));
  }

  void close([int code = 1000, String reason = 'Normal closure']) {
    if (_state == RelayE2eeChannelState.closed) return;
    _state = RelayE2eeChannelState.closed;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Channel closed during handshake'));
    }
    _transportClose(code, reason);
  }

  void transportClosed([int code = 0, String reason = '']) {
    if (_state == RelayE2eeChannelState.closed) return;
    _state = RelayE2eeChannelState.closed;
    if (!_ready.isCompleted) {
      _ready.completeError(
        StateError('Connection closed during handshake: $code $reason'),
      );
    }
  }

  void _handleInitialHello(Object data) {
    try {
      final hello = _parseHello(data);
      if (hello == null) {
        throw FormatException(
          'Invalid hello message (expected e2ee_hello with key)',
        );
      }
      _sharedKey = deriveRelaySharedKey(
        secretKey: _daemonKeyPair.secretKey,
        peerPublicKey: importRelayPublicKey(hello),
      );
      _transportSend('{"type":"e2ee_ready"}');
      _state = RelayE2eeChannelState.open;
      if (!_ready.isCompleted) _ready.complete();
    } on Object catch (error) {
      _fail(error);
    }
  }

  void _handleRehello(String clientPublicKeyB64) {
    try {
      final nextSharedKey = deriveRelaySharedKey(
        secretKey: _daemonKeyPair.secretKey,
        peerPublicKey: importRelayPublicKey(clientPublicKeyB64),
      );
      if (_constantTimeEquals(nextSharedKey, _sharedKey!)) {
        _transportSend('{"type":"e2ee_ready"}');
        return;
      }
      _state = RelayE2eeChannelState.closed;
      _transportClose(
        relayRehandshakeKeyMismatchCloseCode,
        relayRehandshakeKeyMismatchCloseReason,
      );
    } on Object catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    _onError?.call(error);
    _state = RelayE2eeChannelState.closed;
    if (!_ready.isCompleted) _ready.completeError(error);
    _transportClose(1011, '$error');
  }
}

String? _parseHello(Object data) {
  try {
    final text = switch (data) {
      String() => data,
      Uint8List() => utf8.decode(data, allowMalformed: false),
      List<int>() => utf8.decode(data, allowMalformed: false),
      _ => '',
    };
    final decoded = jsonDecode(text);
    if (decoded is! Map ||
        decoded['type'] != 'e2ee_hello' ||
        decoded['key'] is! String ||
        (decoded['key']! as String).trim().isEmpty) {
      return null;
    }
    return decoded['key']! as String;
  } on Object {
    return null;
  }
}

bool _isReadyMessage(Object data) {
  try {
    final text = switch (data) {
      String() => data,
      Uint8List() => utf8.decode(data, allowMalformed: false),
      List<int>() => utf8.decode(data, allowMalformed: false),
      _ => '',
    };
    final decoded = jsonDecode(text);
    return decoded is Map && decoded['type'] == 'e2ee_ready';
  } on Object {
    return false;
  }
}

bool _looksLikePlaintextJson(Object data) {
  try {
    final text = switch (data) {
      String() => data,
      Uint8List() => utf8.decode(data, allowMalformed: false),
      List<int>() => utf8.decode(data, allowMalformed: false),
      _ => '',
    };
    if (!text.trimLeft().startsWith('{')) return false;
    return jsonDecode(text) is Map;
  } on Object {
    return false;
  }
}

bool _constantTimeEquals(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
