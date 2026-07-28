import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'relay_crypto.dart';

typedef RelayTransportSend = void Function(Object data);
typedef RelayTransportClose = FutureOr<void> Function(int code, String reason);
typedef RelayMessageHandler = void Function(Object data);

enum RelayE2eeChannelState { handshaking, open, closed }

/// Paseo-compatible initiator-side encrypted relay channel.
final class RelayE2eeClientChannel {
  RelayE2eeClientChannel({
    required String daemonPublicKeyB64,
    required RelayTransportSend transportSend,
    required RelayTransportClose transportClose,
    required RelayMessageHandler onMessage,
    void Function(Object error)? onError,
    RelayKeyPair? keyPair,
    this.handshakeRetry = const Duration(seconds: 1),
    this.maxPendingSends = 200,
  }) : _transportSend = transportSend,
       _transportClose = transportClose,
       _onMessage = onMessage,
       _onError = onError,
       _keyPair = keyPair ?? RelayKeyPair.generate() {
    final daemonPublicKey = importRelayPublicKey(daemonPublicKeyB64);
    _sharedKey = deriveRelaySharedKey(
      secretKey: _keyPair.secretKey,
      peerPublicKey: daemonPublicKey,
    );
    _helloText = jsonEncode({
      'type': 'e2ee_hello',
      'key': exportRelayPublicKey(_keyPair.publicKey),
    });
  }

  final Duration handshakeRetry;
  final int maxPendingSends;
  final RelayTransportSend _transportSend;
  final RelayTransportClose _transportClose;
  final RelayMessageHandler _onMessage;
  final void Function(Object error)? _onError;
  final RelayKeyPair _keyPair;
  late final Uint8List _sharedKey;
  late final String _helloText;
  final _ready = Completer<void>();
  final List<Object> _pendingSends = [];
  Timer? _retryTimer;
  RelayE2eeChannelState _state = RelayE2eeChannelState.handshaking;

  Future<void> get ready => _ready.future;
  RelayE2eeChannelState get state => _state;
  String get clientPublicKeyB64 => exportRelayPublicKey(_keyPair.publicKey);

  void start() {
    if (_state != RelayE2eeChannelState.handshaking || _retryTimer != null) {
      return;
    }
    _sendHello();
    _retryTimer = Timer.periodic(handshakeRetry, (_) {
      if (_state == RelayE2eeChannelState.handshaking) _sendHello();
    });
  }

  void handleFrame(Object data) {
    if (_state == RelayE2eeChannelState.closed) return;
    if (_state == RelayE2eeChannelState.handshaking) {
      if (_isReadyMessage(data)) _open();
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
      _onMessage(decryptRelayPayload(_sharedKey, bundle));
    } on Object catch (error) {
      _fail(error);
    }
  }

  void send(Object data) {
    if (_state == RelayE2eeChannelState.handshaking) {
      if (_pendingSends.length >= maxPendingSends) {
        _pendingSends.removeAt(0);
      }
      _pendingSends.add(data);
      return;
    }
    if (_state != RelayE2eeChannelState.open) {
      throw StateError('Channel not open');
    }
    final bundle = encryptRelayPayload(_sharedKey, data);
    _transportSend(base64.encode(bundle));
  }

  void close([int code = 1000, String reason = 'Normal closure']) {
    if (_state == RelayE2eeChannelState.closed) return;
    _state = RelayE2eeChannelState.closed;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Channel closed during handshake'));
    }
    _transportClose(code, reason);
  }

  void transportClosed([int code = 0, String reason = '']) {
    if (_state == RelayE2eeChannelState.closed) return;
    _state = RelayE2eeChannelState.closed;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_ready.isCompleted) {
      _ready.completeError(
        StateError('Connection closed during handshake: $code $reason'),
      );
    }
  }

  void _sendHello() {
    try {
      _transportSend(_helloText);
    } on Object catch (error) {
      _onError?.call(error);
    }
  }

  void _open() {
    _state = RelayE2eeChannelState.open;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_ready.isCompleted) _ready.complete();
    final pending = List<Object>.of(_pendingSends);
    _pendingSends.clear();
    for (final data in pending) {
      send(data);
    }
  }

  void _fail(Object error) {
    _onError?.call(error);
    _state = RelayE2eeChannelState.closed;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_ready.isCompleted) _ready.completeError(error);
    _transportClose(1011, '$error');
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
    final decoded = jsonDecode(text);
    return decoded is Map;
  } on Object {
    return false;
  }
}
